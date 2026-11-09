# devinfra

The infrastructure half of the `devstack` repository, split out so it can run
without the disposable VM that repository ships: PostgreSQL + PostGIS + pgvector,
Valkey, an agent gateway that fronts several LLM providers and three MCP servers,
and a headless Playwright browser — all as rootless Podman Quadlets on one bridge
network, `devnetng.network`.

There is no VM here. devstack ships a disposable systemd container (`fakevm`) and
the skeleton files that go inside it; this repository ships only the services
those environments talk to. Install it on the machine that already *is* the
development environment, or on a host that several of them share.

> Status: scaffolding, ported from devstack and then deliberately diverged in the
> places fakevm was holding the stack together. Sections marked `TODO` are
> placeholders. devstack's own README remains the reference for anything the two
> still share.

## Contents

- [Two ways to use this](#two-ways-to-use-this)
- [Components](#components)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Install](#install)
- [Start, stop, boot](#start-stop-boot)
- [Clients](#clients)
- [Reaching the stack from another machine](#reaching-the-stack-from-another-machine)
- [Networking and ports](#networking-and-ports)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Roadmap / TODO](#roadmap--todo)

## Two ways to use this

| Shape | Where the stack runs | What talks to it |
|---|---|---|
| **Co-located** | On the machine you develop on | The same machine, over loopback |
| **Shared** | On one host, kept running | Several machines, over a tunnel or a private network |

Both shapes run the identical units; the difference is how a client reaches
them and whether the units are enabled at boot. Nothing in `quadlets/` changes
between them — the published ports are loopback-only either way, and a remote
client arrives through an SSH tunnel or a private link rather than through a
port opened to the world. [Reaching the stack from another
machine](#reaching-the-stack-from-another-machine) covers the exceptions and why
they are not the default.

What this repository does **not** provide is the development environment itself:
no editor setup, no `fnm`/`uv`/`pnpm`, no agent config beyond the client
examples in `clients/`. That is the point of the split — the machines on the
client side live in their own repositories (`devstack`'s `fakevm`, or a real VM's
usual provisioning), and they only need a handful of endpoints and tokens from
here.

## Components

| Component | Unit | Image | Purpose |
|---|---|---|---|
| Network | `devnetng.network` | — | Bridge network shared by every container |
| PostgreSQL | `postgres.container` (image built by `postgisvec.build`) | `localhost/quadlet/postgisvec:latest` | Development database, port 5432 |
| Valkey | `valkey.container` | `docker.io/valkey/valkey:9-trixie` | Development cache, port 6379 |
| Agent gateway | `agentgateway.container` | `cr.agentgateway.dev/agentgateway:v1.7.0` | LLM proxy + GitHub/Playwright MCP proxies + admin UI, ports 38080 (UI) and 4000 (API) |
| Playwright MCP | `playwrightmcp.container` | `mcr.microsoft.com/playwright/mcp:v0.0.83` | Headless Chromium over MCP, port 8931 |
| Forgejo MCP | `forgejomcp.container` (image built by `forgejomcp.build`) | `localhost/quadlet/forgejomcp:latest` (built) | MCP server for a Forgejo instance over streamable HTTP, port 8080 |

## Repository layout

```
AGENTS.md           Guidance for coding agents working in this repo
THIRD-PARTY.md      Licences of third-party code built into these images
builds/
  forgejomcp/       Containerfile for the Forgejo MCP server (release bundles are not committed)
  postgisvec/       Containerfile for PostgreSQL + PostGIS + pgvector
clients/pi/         Client config templates for an external dev environment
data/               Persistent state (gitignored)
  agentgateway/     Gateway config.yaml, model catalog, SQLite databases
  playwrightmcp/    Browser output directory (screenshots, downloads)
  postgres/         Database data directory
  valkey/           Cache data directory
envars/             Environment files consumed by the Quadlets (gitignored)
install.sh          Entry point: run the three scripts/ steps in order
quadlets/           Podman Quadlet unit files
scripts/            Host-side scripts; all of them resolve paths from the repo root
  link-quadlets.sh  Symlink quadlets/ into the rootless Quadlet search path
  manage-stack.sh   Start, stop and inspect the units
  pre-setup.sh      Fetch the forgejo-mcp release bundles (gitignored build input)
  setup.sh          Rebuild dirs, copy *.example templates
```

### What is committed

Nothing under `data/`, `envars/` or `clients/` is tracked except `*.example`
templates, so no private key, token or credential is ever in history.
`scripts/setup.sh` is what rebuilds the ignored tree, which is why a fresh clone
needs it before anything can start.

`builds/forgejomcp/binaries/` is ignored for a different reason, and is the one
build input git cannot carry: it holds upstream release binaries, and committing
them would make this repository their distributor. `scripts/pre-setup.sh` fetches
them. See [`THIRD-PARTY.md`](THIRD-PARTY.md).

## Prerequisites

- Rootless Podman 4.x or newer (Quadlet support)
- systemd user session
- `openssl` (secret generation)
- `curl` and `sha256sum` (the forgejo-mcp bundle fetch)
- Network access to pull the base images on first run

`TODO:` document the minimum tested versions and the host OS.

For the shared shape, the host also needs `loginctl enable-linger <user>` if the
stack is expected to come back after a reboot without anyone logging in — a user
manager that only starts on login cannot start units at boot, `[Install]
WantedBy=default.target` or not.

## Configuration

Secrets and tunables live in `envars/`, which the Quadlets load through
`EnvironmentFile=`. Only the `*.example` templates are committed: `scripts/setup.sh`
copies each one to its real name (minus the suffix) and the real files are
gitignored. Fill in the values before starting the stack.

`envars/postgres.env`

| Variable | Description |
|---|---|
| `POSTGRES_PASSWORD` | Database password for the `postgres` superuser |

`envars/agentgateway.env`

| Variable | Description |
|---|---|
| `AGENTGW_SESSION_KEY` | Session signing key — `openssl rand -hex 32` |
| `DEEPSEEK_API_KEY` | DeepSeek API key |
| `ZAI_API_KEY` | Z.ai API key |
| `OPENROUTER_API_KEY` | OpenRouter API key — serves Kimi K3.1 Pro |
| `GITHUB_MCP_PAT` | GitHub PAT used by the MCP proxy (read-only scope recommended) |
| `DOWNSTREAM_DEEPSEEK_SEARCH_TOKEN` | Bearer token clients present to the DeepSeek proxy — random |
| `DOWNSTREAM_GITHUB_MCP_TOKEN` | Bearer token clients present to the GitHub MCP proxy — random (must match `clients/pi/mcp.json`) |
| `DOWNSTREAM_PLAYWRIGHT_MCP_TOKEN` | Bearer token clients present to the Playwright MCP proxy — random (must match `clients/pi/mcp.json`) |

The three `DOWNSTREAM_*` tokens are shared, not per-client: one value per route,
rotated in this file and in every client at once. There is no per-environment
identity on the LLM or GitHub routes yet — see [Roadmap](#roadmap--todo).

`envars/forgejomcp.env`

| Variable | Description |
|---|---|
| `FORGEJO_URL` | URL of the Forgejo instance the server talks to — contacted at startup; the server exits if it is unreachable |
| `FORGEJO_ACCESS_TOKEN` | Forgejo access token: Settings → Applications → Access Tokens. Wanted at startup; with the fallback off it is never used to serve a request |
| `FORGEJO_MCP_ALLOWED_HOSTS` | `Host` names the server answers to, matched exactly with no wildcard. The template covers `systemd-forgejomcp` and both loopback families; a name missing here is a `403` on every request |
| `FORGEJO_MCP_ALLOW_OPERATOR_TOKEN_FALLBACK` | `0` in this stack. `1` would serve a request with no `Authorization` header using `FORGEJO_ACCESS_TOKEN` — which is what devstack does, safely, because it publishes no port. Here the port **is** published, so this stays off; see [Forgejo MCP](#forgejo-mcp) |

The admin UI also expects an htpasswd file at
`data/agentgateway/agwadmins.htpasswd`. There is no template for it, so
`scripts/setup.sh` cannot create it — make it by hand once:

```bash
htpasswd -c data/agentgateway/agwadmins.htpasswd admin
```

The gateway configuration follows the same rule:
`data/agentgateway/config.yaml.example` is the template and the generated
`config.yaml` is gitignored.

That template carries the price catalog inline, under `config.modelCatalog`, as
per-model rates (`input`, `output`, `cacheRead`). There is no bundled price list,
so base prices have to be downloaded from the gateway's admin UI and kept up to
date by hand. **When you add a model, add its rates there in the same commit.**
Nothing fills them in for you. Missing rates are not fatal: the model still
serves requests, it just logs no estimated price and stays out of the cost
analysis view, so the estimates quietly run low. The same rates appear again in
`clients/pi/models.json` — that copy is what a client shows you, and it goes
stale on its own.

## Install

Quadlets reference `%h/Containers/devinfra` (systemd expands `%h` to your home
directory), so this repository is expected to live — or be symlinked — at
`~/Containers/devinfra`. `scripts/link-quadlets.sh` compares the two and warns
when they disagree:

```bash
mkdir -p ~/Containers
ln -s "$PWD" ~/Containers/devinfra
```

Rebuild the ignored tree, fetch the build inputs and link the units into the
rootless Quadlet search path (`$XDG_CONFIG_HOME/containers/systemd`, default
`~/.config/containers/systemd`):

```bash
./install.sh
systemctl --user daemon-reload
```

`install.sh` runs the three steps in `scripts/` in order:
`scripts/pre-setup.sh` fetches the forgejo-mcp release bundles,
`scripts/setup.sh` rebuilds the ignored tree, and `scripts/link-quadlets.sh`
links the units. Run them individually when only one is needed — none of them
minds being called twice, and `install.sh` only stops early when a step fails.

`scripts/pre-setup.sh` is the only step that needs the network, and only for the
`forgejomcp` image: it downloads the releases that image is built from and
verifies each against a pinned sha256. Re-running it is free — a bundle already
present is skipped — so it can sit in a deploy script unconditionally.

`scripts/setup.sh` needs no container runtime — it only creates directories and
copies templates (never overwriting an existing file).

## Start, stop, boot

`scripts/manage-stack.sh` is the one command that brings the stack up. In
devstack, `fakevm.container` `Wants=` every other unit and starting the VM
started everything; there is no such anchor here, and adding one would make the
stack start the wrong things in the wrong order for a shared host. So the order
lives in the script:

```bash
./scripts/manage-stack.sh up        # start everything, in order
./scripts/manage-stack.sh status    # per-unit state, plus the endpoints
./scripts/manage-stack.sh down      # stop it again
./scripts/manage-stack.sh restart
```

Starting is not enabling. The units carry `[Install]
WantedBy=default.target`, so a host that should serve this stack across reboots
enables them once, explicitly:

```bash
systemctl --user enable postgres.service valkey.service agentgateway.service \
    playwrightmcp.service forgejomcp.service
```

`[Install]` is a deliberate divergence from devstack, which has none on purpose:
there the stack belongs to a disposable VM and nothing should start at boot. Here
the stack is infrastructure, and on a shared host "it came back after the reboot"
is the requirement. `manage-stack.sh up` still starts without enabling, so a
throwaway host is not turned into a permanent one by trying it out.

Images defined by a `.build` unit are built on first start. `forgejomcp` is the
one unit that can look broken while the rest works: it dials `FORGEJO_URL` at
startup and exits when it cannot reach it, so under the shipped template it
restarts every 30 seconds instead of serving. Fill in `FORGEJO_URL` and
`FORGEJO_ACCESS_TOKEN` first; nothing else depends on it, so the rest of the
stack is unaffected.

## Clients

`clients/pi/` holds the three config files a Pi client needs, with the endpoints
already pointed at loopback:

| File | Goes to | What to change |
|---|---|---|
| `models.json` | `~/.pi/agent/models.json` | nothing, unless the models or their rates change |
| `mcp.json` | `~/.pi/agent/mcp.json` | the three `Bearer <…>` placeholders → the matching `DOWNSTREAM_*` tokens |
| `web-search.json` | `~/.pi/agent/web-search.json` | `deepseekApiKey` → `DOWNSTREAM_DEEPSEEK_SEARCH_TOKEN` |

`scripts/setup.sh` also copies them to the same directory without the `.example`
suffix, so the tree always has a fill-in-the-blank copy next to the template.
They are the client half of the shared-stack story: the provider keys, the GitHub
PAT and the Forgejo token stay on this host, and a client only ever holds a
gateway token.

Two endpoints are *not* on the gateway — PostgreSQL and Valkey — because they are
protocol servers rather than HTTP and each client connects to them directly. Same
loopback/tunnel rule applies.

The one thing these templates cannot do for you is point at a host other than
`127.0.0.1`. That default works for a co-located stack and for a tunnel; a client
on a private network replaces `127.0.0.1` with the address it reaches. Keep the
port numbers: they are what the gateway and the MCP servers expect.

## Reaching the stack from another machine

Every published port is bound to loopback (`127.0.0.1` and `[::1]`). That is not
timidity about the network — it is the only thing standing between a dev machine
and the provider keys, because the LLM listener has no client authentication you
can rely on: `llm.policies.apiKey` ships empty (`mode: strict`, `keys: []`), so no
client presents a key. Do not widen it before adding virtual keys and checking
that a request *without* one is refused.

Three ways to reach it, in ascending order of trust:

1. **SSH tunnel** — no change to any unit, and the client keeps the loopback
   URLs above verbatim:

   ```bash
   ssh -N -L 4000:127.0.0.1:4000 -L 8080:127.0.0.1:8080 -L 5432:127.0.0.1:5432 \
       -L 6379:127.0.0.1:6379 -L 38080:127.0.0.1:38080 devuser@infra-host
   ```

2. **Private network** (WireGuard, Tailscale, a lab VLAN) — change the
   `PublishPort=` lines to bind the interface those networks use, e.g.
   `PublishPort=<that-ip>:4000:4000/tcp`, then `systemctl --user daemon-reload`
   and restart the unit. Clients then use `http://<that-ip>:4000` and need no
   tunnel. The address is a property of the host, not of this repository, which
   is why it is an edit rather than a setting.

3. **A LAN address** — possible, and the same edit, but understand what is being
   published: an unauthenticated LLM API backed by your provider keys, an
   unauthenticated browser (if 8931 is published), and a Postgres superuser. This
   is the shape to pick only on a network where every host is already trusted
   with the keys themselves.

What must not be published in any shape is the Playwright port: it has no
authentication of its own, and `--allowed-hosts "*"`. That is why the stack
serves it through the gateway's `/mcp/playwright` route instead, with a bearer
token, and why `quadlets/playwrightmcp.container` has no `PublishPort=`.

### Forgejo MCP

`forgejomcp` is the one service whose exposure decision is not just "loopback or
not". Two settings have to agree:

- **The fallback is off.** `FORGEJO_MCP_ALLOW_OPERATOR_TOKEN_FALLBACK=0`, so a
  request with no `Authorization` header is refused with `401` instead of being
  served with `FORGEJO_ACCESS_TOKEN`. This is the inverse of devstack, which has
  it on because its only client is a container on `devnetng` that sends no
  credential. Off is both safer and the better model for several development
  environments: each one presents its own read-only Forgejo token, and revoking
  one does not disturb the others.
- **The port is published on loopback**, which is only safe *because* of the
  point above. With fallback on, a published port would let any local process act
  as the operator's Forgejo user. With it off, a local process can only do what
  its own token allows — which it could do by calling Forgejo directly.

The server matches the `Host` header exactly against `FORGEJO_MCP_ALLOWED_HOSTS`.
A client behind an SSH tunnel sends `127.0.0.1:8080` and is covered by the
template; a client on a private network sends its own name and needs that name
added to the env file, or every request is a `403` naming the header it refused.

`TODO:` front Forgejo through the gateway like GitHub and Playwright, so one port
and one token model covers every MCP server. It was not done here because the
gateway's `Host` header behaviour toward a backend is unverified, and
`forgejomcp` turns a wrong `Host` into a `403` on every request rather than a
connection error.

## Networking and ports

All containers join `systemd-devnetng` (from `devnetng.network`). Host ports are
bound to loopback only unless [Reaching the stack from another
machine](#reaching-the-stack-from-another-machine) says otherwise.

| Container port | Host binding | Reachable from a remote client |
|---|---|---|
| 5432 (PostgreSQL) | `127.0.0.1:5432`, `[::1]:5432` | via tunnel or private network, directly |
| 6379 (Valkey) | `127.0.0.1:6379`, `[::1]:6379` | via tunnel or private network, directly |
| 38080 (gateway UI) | `127.0.0.1:38080`, `[::1]:38080` | via tunnel; HTTP basic auth |
| 4000 (gateway LLM + GitHub/Playwright MCP) | `127.0.0.1:4000`, `[::1]:4000` | via tunnel or private network; **no client auth on the LLM listener** |
| 8080 (Forgejo MCP) | `127.0.0.1:8080`, `[::1]:8080` | via tunnel or private network; per-request token required |
| 8931 (Playwright MCP) | not published — gateway route only | through `/mcp/playwright` |

Inside the network, the container names are the hostnames: `systemd-postgres`,
`systemd-valkey`, `systemd-agentgateway`, `systemd-playwrightmcp`,
`systemd-forgejomcp`. Quadlet prefixes `systemd-`; using the unit's own name
(`postgres`) resolves to nothing.

`TODO:` add a diagram.

### Verify a fresh install

```bash
curl -sS http://127.0.0.1:4000/v1/models | head          # gateway up, model catalog
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:38080/   # 401 without basic auth
curl -sS -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer $DOWNSTREAM_GITHUB_MCP_TOKEN" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -X POST http://127.0.0.1:4000/mcp/github -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

`TODO:` the Playwright route is newer than the rest and has not been exercised
from this checkout — if `browser_*` tools fail, read `podman logs
systemd-agentgateway` before suspecting the browser container.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Network 'systemd-devnetng' does not exist` | Start/reload the network unit: `systemctl --user daemon-reload && systemctl --user start devnetng-network` |
| Quadlet unit name is `systemd-<name>` | Podman Quadlet prefixes container names; use `systemd-agentgateway`, not `agentgateway`, as a hostname |
| `Unit ... not found` after adding a unit | Re-run `./scripts/link-quadlets.sh` and `systemctl --user daemon-reload` |
| A unit silently fails to generate | Unsupported key in the unit, or an `Image=`/`Network=` naming a quadlet that is not in `quadlets/`; the generator refuses to translate a missing dependency |
| Volumes point at an empty directory | The checkout is not at `~/Containers/devinfra`; `scripts/link-quadlets.sh` warns about this |
| Gateway returns 401 | `DOWNSTREAM_*_TOKEN` mismatch between client and `agentgateway.env` |
| Gateway returns 403/404 on `/mcp/playwright` | The route did not load — check the gateway log for a config error; the whole gateway fails rather than one route |
| `systemd-forgejomcp` restarts every 30s | `envars/forgejomcp.env` still holds a template placeholder, or `FORGEJO_URL` is unreachable from the container. Check `podman logs systemd-forgejomcp`; the unit exits rather than serving when it cannot reach Forgejo |
| Forgejo MCP returns 403 | The `Host` header the client sends is not in `FORGEJO_MCP_ALLOWED_HOSTS`; it is matched exactly, with no wildcard |
| Forgejo MCP returns 401 | `FORGEJO_MCP_ALLOW_OPERATOR_TOKEN_FALLBACK=0` and the request carried no `Authorization` header — that is the intended answer, send your own token |
| Unit starts at boot but nothing answers | The user manager is not lingering: `loginctl enable-linger $USER` |
| Screenshots not visible on this host | They are written to `data/playwrightmcp/` on the *infrastructure* host, owned by a mapped subuid; copy them across, they are world-readable |

`TODO:` add log locations and a reset procedure.

## Security notes

- `data/`, `envars/` and `clients/` are gitignored apart from `*.example`
  templates, so no tracked file ever holds a secret.
- Every published port is on loopback. The LLM listener has no client
  authentication: treat "can open a socket to 4000" as "can spend the provider
  keys".
- The gateway admin UI is protected by HTTP basic auth; keep it on loopback.
- `GITHUB_MCP_PAT` is intended to be read-only; write tools will fail with 403.
- `FORGEJO_ACCESS_TOKEN` is not served to headerless requests here
  (`FORGEJO_MCP_ALLOW_OPERATOR_TOKEN_FALLBACK=0`). Publishing the fallback-on
  combination would hand the operator's Forgejo identity to any local process.
- Playwright is not published: anything on `devnetng` that can reach 8931 can
  drive a browser with whatever credentials that browser can hold, and the
  container runs with `--allowed-hosts "*"`. It is served over the gateway so a
  client outside the network needs a bearer token to get there.
- Env files created by `scripts/setup.sh` are chmod `600`, since they are where
  the API keys and proxy tokens end up.
- Both stacks on one host is not a supported layout: the unit names, the network
  name and the loopback ports would collide. Run one.

## Roadmap / TODO

- [ ] Virtual keys on the LLM listener, so 4000 can be published deliberately
      (and so cost per development environment can be seen)
- [ ] Per-client `DOWNSTREAM_*` tokens instead of one shared value per route
- [ ] Forgejo through the gateway (`/mcp/forgejo`), replacing the published 8080
- [ ] Per-host overrides — today a private-network bind means editing the unit
- [ ] `Makefile` / `justfile` for build, install and teardown
- [ ] Validate envars before starting units
- [ ] Health checks for postgres/valkey/gateway
- [ ] Document the agent gateway routes and policies in detail
- [ ] Add backups for `data/postgres`
