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
them and whether the units are enabled at boot. Nothing in `skel/quadlets/`
changes between them — the published ports are loopback-only either way, and a
remote client arrives through an SSH tunnel or a private link rather than through
a port opened to the world. [Reaching the stack from another
machine](#reaching-the-stack-from-another-machine) covers the exceptions and why
they are not the default.

What this repository does **not** provide is the development environment itself:
no editor setup, no `fnm`/`uv`/`pnpm`, no agent config, and no client configs —
those belong to the client and live with it. That is the point of the split: the
machines on the client side live in their own repositories (`devstack`'s
`fakevm`, or a real VM's usual provisioning), and they need only a handful of
endpoints and tokens from here.

## Components

| Component | Unit | Image | Purpose |
|---|---|---|---|
| Network | `devnetng.network` | — | Bridge network shared by every container |
| PostgreSQL | `postgres.container` (image built by `postgisvec.build`) | `localhost/quadlet/postgisvec:latest` | Development database, port 5432 |
| Valkey | `valkey.container` | `docker.io/valkey/valkey:9-trixie` | Development cache, port 6379 |
| Agent gateway | `agentgateway.container` | `cr.agentgateway.dev/agentgateway:v1.7.0` | LLM proxy + GitHub/Playwright/Forgejo MCP proxies + admin UI, ports 38080 (UI) and 4000 (API) |
| Playwright MCP | `playwrightmcp.container` | `mcr.microsoft.com/playwright/mcp:v0.0.83` | Headless Chromium over MCP, port 8931 |
| Forgejo MCP | `forgejomcp.container` (image built by `forgejomcp.build`) | `localhost/quadlet/forgejomcp:latest` (built) | MCP server for a Forgejo instance over streamable HTTP, port 8080 inside `devnetng` |

## Repository layout

```
AGENTS.md           Guidance for coding agents working in this repo
THIRD-PARTY.md      Licences of third-party code built into these images
builds/
  forgejomcp/       Containerfile for the Forgejo MCP server (release bundles are not committed)
  postgisvec/       Containerfile for PostgreSQL + PostGIS + pgvector
installed/          This machine's install: seeded from skel/, gitignored, edited here
  quadlets/         The units systemd loads (what link-quadlets.sh links)
  envars/           Environment files the units load; 0600, real values
  data/             Persistent state
    agentgateway/   Gateway config.yaml, model catalog, SQLite databases
    playwrightmcp/  Browser output directory (screenshots, downloads)
    postgres/       Database data directory
    valkey/         Cache data directory
install.sh          Entry point: run the three scripts/ steps in order
scripts/            Host-side scripts; all of them resolve paths from the repo root
  link-quadlets.sh  Symlink installed/quadlets/ into the rootless Quadlet search path
  manage-stack.sh   Start, stop and inspect the units
  pre-setup.sh      Fetch the forgejo-mcp release bundles (gitignored build input)
  setup.sh          Seed installed/ from skel/
skel/               Tracked seeds, copied into installed/ and never edited in place
  quadlets/         Podman Quadlet unit files (@REPO_ROOT@ substituted at seed time)
  envars/           Environment file seeds, holding placeholder values
  data/             Gateway config seed
```

### What is committed

Only `skel/` is tracked, and `installed/` is ignored as a whole, so no credential
is ever in history: the real values live in `installed/envars/*.env`, which is
what `scripts/setup.sh` creates from the seeds. `skel/envars/*.env` is itself a
tracked file — it ships placeholders, and a real key pasted into it is a
committed secret even though the copy under `installed/` is the one in use.

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

Secrets and tunables live in `installed/envars/`, which the Quadlets load through
`EnvironmentFile=`. The tracked seeds in `skel/envars/` hold placeholder values;
`scripts/setup.sh` copies them to `installed/envars/` at `0600` and that copy is
where the real values go. It is never overwritten, so a value added to a seed does
not reach an existing install — re-run after a pull and read the drift report.
The exception is the gateway's session key and its downstream route tokens:
those are generated on that first copy, so the seed's placeholders never reach a
running install and no token is committed.

`installed/envars/postgres.env`

| Variable | Description |
|---|---|
| `POSTGRES_PASSWORD` | Database password for the `postgres` superuser |

`installed/envars/agentgateway.env`

| Variable | Description |
|---|---|
| `AGENTGW_SESSION_KEY` | Session signing key — `openssl rand -hex 32`; generated by `scripts/setup.sh` |
| `DEEPSEEK_API_KEY` | DeepSeek API key |
| `ZAI_API_KEY` | Z.ai API key |
| `OPENROUTER_API_KEY` | OpenRouter API key — serves Kimi K3.1 Pro |
| `GITHUB_MCP_PAT` | GitHub PAT used by the MCP proxy (read-only scope recommended) |
| `DOWNSTREAM_DEEPSEEK_SEARCH_TOKEN` | Bearer token clients present to the DeepSeek proxy — 32 alphanumeric characters, generated by `scripts/setup.sh` |
| `DOWNSTREAM_GITHUB_MCP_TOKEN` | Bearer token clients present to the GitHub MCP proxy — generated by `scripts/setup.sh` (must match what your client sends) |
| `DOWNSTREAM_PLAYWRIGHT_MCP_TOKEN` | Bearer token clients present to the Playwright MCP proxy — generated by `scripts/setup.sh` (must match what your client sends) |

The three `DOWNSTREAM_*` tokens are shared, not per-client: one value per route,
rotated in this file and in every client at once. The proxies have no
per-environment identity yet — see [Roadmap](#roadmap--todo). The LLM listener is
the exception: each environment can hold its own virtual key, minted in the
dashboard, so its spend is attributable and revocable on its own. See [Virtual
keys](#virtual-keys-llm-access).

`installed/envars/forgejomcp.env`

| Variable | Description |
|---|---|
| `FORGEJO_URL` | URL of the Forgejo instance the server talks to — contacted at startup; the server exits if it is unreachable |
| `FORGEJO_ACCESS_TOKEN` | Forgejo access token: Settings → Applications → Access Tokens. Wanted at startup; with the fallback off it is never used to serve a request |
| `FORGEJO_MCP_ALLOWED_HOSTS` | `Host` names the server answers to, matched by host with no wildcard; an entry without a port matches any port, which is why `systemd-forgejomcp` covers the `systemd-forgejomcp:8080` the gateway sends. A name missing here is a `403` on every request |
| `FORGEJO_MCP_ALLOW_OPERATOR_TOKEN_FALLBACK` | `0` in this stack. `1` would serve a request with no `Authorization` header using `FORGEJO_ACCESS_TOKEN` — which is what devstack does, safely, because its only client is a container on `devnetng` that sends no credential. Here the gateway forwards whatever header it was given, so a headerless request served with the operator's token is exactly the identity leak the gateway is meant to prevent; this stays off. See [Forgejo MCP](#forgejo-mcp) |

The admin UI also expects an htpasswd file at
`installed/data/agentgateway/agwadmins.htpasswd`. There is no seed for it, so
`scripts/setup.sh` cannot create it — make it by hand once:

```bash
htpasswd -c installed/data/agentgateway/agwadmins.htpasswd admin
```

The gateway configuration follows the same rule: `skel/data/agentgateway/config.yaml`
is the seed, and `installed/data/agentgateway/config.yaml` — the copy you edit — is
what the container reads.

That seed carries the price catalog inline, under `config.modelCatalog`, as
per-model rates (`input`, `output`, `cacheRead`). There is no bundled price list,
so base prices have to be downloaded from the gateway's admin UI and kept up to
date by hand. **When you add a model, add its rates there in the same commit.**
Nothing fills them in for you. Missing rates are not fatal: the model still
serves requests, it just logs no estimated price and stays out of the cost
analysis view, so the estimates quietly run low. A client may keep its own copy of
those rates; that file lives with the client, outside this repository, and goes
stale on its own.

### Virtual keys (LLM access)

The LLM listener is keyed, and the seed ships it **fail-closed**:
`llm.policies.apiKey` is `mode: strict` with `keys: []`. Strict means a valid key
must be present, and an empty list admits none, so a fresh stack refuses every
`/v1` request with `401` until someone creates a key. `GET /v1/models` answering
`401` is the listener working, not a fault.

Keys are not in the seed and are not edited by hand. They are created at
runtime in the dashboard, which is why 38080 stays on loopback:

1. Reach the UI over a tunnel — `ssh -N -L 38080:127.0.0.1:38080 <user>@<host>` —
   and open `http://127.0.0.1:38080`. Log in with the user from
   `installed/data/agentgateway/agwadmins.htpasswd`.
2. LLM → Virtual API Keys → one key per development environment. The gateway keeps
   a hash, not the key, so the raw value is only visible when it is created.
   In the default file storage the keys are written into
   `installed/data/agentgateway/config.yaml`, which is gitignored; the seed keeps
   `keys: []`, so a fresh checkout still starts closed.
3. Give that key to the environment's client as a bearer token on
   `http://<host>:4000/v1`.

A client config is not part of this repository, but the rule it has to follow is:
it carries the environment's *virtual* key, never a provider key. Pi takes it from
wherever you keep it — `~/.pi/agent/auth.json` via `/login`, `--api-key`, or the
provider's environment variable — and interpolates `$NAME` at request time, so
pinning it in the config is one line beside `baseUrl`:

```json
"apiKey": "$AGENTGATEWAY_VIRTUAL_KEY"
```

Never switch the mode to `optional` — the gateway's own default when `mode` is
omitted — or to `permissive`, and never drop the `apiKey` policy: those admit
requests with no key at all. And per key, `allowedModels` and `budgets` limit which
models an environment may call and what it may spend; a budget needs
`metadata.name` on the key and `config.database.url` in this file, which the
seed already sets.

## Install

The checkout can live anywhere. `scripts/setup.sh` substitutes this tree's
absolute path for `@REPO_ROOT@` in the units while seeding, so
`EnvironmentFile=`, `Volume=` and `SetWorkingDirectory=` name real directories
wherever you cloned it — no symlink, and no assumption about your home directory.
Moving the tree afterwards means re-seeding: `rm -rf installed/ &&
./scripts/setup.sh`.

Seed `installed/`, fetch the build inputs and link the units into the rootless
Quadlet search path (`$XDG_CONFIG_HOME/containers/systemd`, default
`~/.config/containers/systemd`):

```bash
./install.sh
systemctl --user daemon-reload
```

`install.sh` runs the three steps in `scripts/` in order:
`scripts/pre-setup.sh` fetches the forgejo-mcp release bundles,
`scripts/setup.sh` seeds `installed/` from `skel/`, and
`scripts/link-quadlets.sh` links `installed/quadlets/`. Run them individually when
only one is needed — none of them minds being called twice, and `install.sh` only
stops early when a step fails.

`scripts/pre-setup.sh` is the only step that needs the network, and only for the
`forgejomcp` image: it downloads the releases that image is built from and
verifies each against a pinned sha256. Re-running it is free — a bundle already
present is skipped — so it can sit in a deploy script unconditionally.

`scripts/setup.sh` needs no container runtime — it only creates directories and
copies seeds, and it never overwrites an existing file. That is deliberate:
`installed/` is where this machine's decisions live, and the consequence is that a
`git pull` changes `skel/` and does not reach `installed/`. The run ends with a
`differs` line for every seed that disagrees with the install; `diff -rq skel/
installed/` shows what would change, and the merge is yours.

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
startup and exits when it cannot reach it, so under the shipped seed it
restarts every 30 seconds instead of serving. Fill in `FORGEJO_URL` and
`FORGEJO_ACCESS_TOKEN` first; nothing else depends on it, so the rest of the
stack is unaffected.

## Reaching the stack from another machine

Every published port is bound to loopback (`127.0.0.1` and `[::1]`) by default.
Port 4000 is the one a remote client will usually need widened, and it is safe to
widen because everything behind it is credential-checked: `/v1` needs a virtual
key (`llm.policies.apiKey` is `mode: strict`, so a request without one is
refused — see [Virtual keys](#virtual-keys-llm-access)), and each MCP route above
it needs its own token. A fresh stack refuses `/v1` until the first key is
created, which is the listener working as intended rather than a fault.

Port 38080 is the deliberate exception that stays on loopback. It is the
dashboard that mints virtual keys and edits routes, and HTTP basic auth over an
unencrypted port is the whole of its authentication; reach it through a tunnel.

How to reach 4000, in ascending order of trust:

1. **SSH tunnel** — no change to any unit, and the client keeps the loopback
   URLs above verbatim:

   ```bash
   ssh -N -L 4000:127.0.0.1:4000 -L 5432:127.0.0.1:5432 \
       -L 6379:127.0.0.1:6379 -L 38080:127.0.0.1:38080 devuser@infra-host
   ```

   Every MCP server comes with the 4000 forward, Forgejo included, and 38080
   rides along for provisioning keys from the dashboard.

2. **Private network** (WireGuard, Tailscale, a lab VLAN) — edit the
   `PublishPort=` lines in `installed/quadlets/` to bind the interface those
   networks use, e.g. `PublishPort=<that-ip>:4000:4000/tcp`, then `systemctl --user
   daemon-reload` and restart the unit. This is a deployment edit, and it is why
   `installed/quadlets/` exists: the tracked `skel/quadlets/` stays on loopback as
   the reviewed default, so a pull never undoes it. Clients then use
   `http://<that-ip>:4000` and need no tunnel. The address is a property of the
   host, not of this repository, which is why it is an edit rather than a setting.
   Leave the 38080 lines on loopback and tunnel to the dashboard when you need to
   create or revoke a key.

3. **A LAN address** — possible, and the same edit, but understand what is being
   published: a key-gated LLM API backed by your provider keys (safe only while
   the mode stays `strict`), whatever MCP routes you have tokens for, and — if
   you widen them too — a Postgres superuser and the basic-auth'd dashboard. This
   is the shape to pick only on a network where every host is already trusted
   with the keys themselves.

What must not be published in any shape is the Playwright port: it has no
authentication of its own, and `--allowed-hosts "*"`. That is why the stack
serves it through the gateway's `/mcp/playwright` route instead, with a bearer
token, and why `skel/quadlets/playwrightmcp.container` has no `PublishPort=`.

### Forgejo MCP

`forgejomcp` is the second service with no `PublishPort=` of its own. Clients
reach it through the gateway's `/mcp/forgejo` route, so the only host port any
MCP client needs is 4000. Two things about that route are worth knowing before
changing it.

**The bearer token on this route is the client's own Forgejo token.**
`forgejo-mcp` reads `Authorization` and forwards that token to Forgejo on every
request, which is how one identity per development environment is preserved —
something a single shared `DOWNSTREAM_*` value cannot express. The route therefore
carries no `authorization` policy of its own, unlike `/mcp/github` and
`/mcp/playwright`: a `require` on that header would have to match one fixed
token, and the only fixed token available is the operator's
(`FORGEJO_ACCESS_TOKEN`, see below), so it would either replace per-client
identity with the operator's or lock every client out. Requests without a token
are refused by `forgejo-mcp` itself.

**The fallback stays off.** `FORGEJO_MCP_ALLOW_OPERATOR_TOKEN_FALLBACK=0` means a
request with no `Authorization` header is refused with `401` instead of being
served with `FORGEJO_ACCESS_TOKEN`. This is the inverse of devstack, which has it
on because its only client is a container on `devnetng` that sends no credential.
With the gateway in front, fallback-on would be worse than it sounds: the gateway
forwards whatever header it was given, so a headerless request would be served
as the operator — the one identity the gateway exists to keep away from clients.

`FORGEJO_MCP_ALLOWED_HOSTS` still governs whether the server answers at all. The
gateway sends the backend's own name, `systemd-forgejomcp:8080`, which the seed
declares; an entry there without a port matches any port. A name missing
from the list is a `403` on every request, and the server logs the `Host` it
refused, so the fix names itself. That check is also the reason to look at this
list, not at the gateway, when `/mcp/forgejo` answers 403.

That last point is the one unproven link in this route. What the gateway forwards
as the authority toward a backend is not something this repository can assert
from documentation: an HTTPS backend demonstrably gets its own name — a request
to `/mcp/github` with a spoofed `Host` still reaches GitHub — but `forgejomcp` is
reached over plain HTTP, and that path was not exercised here. If the first call
through `/mcp/forgejo` answers `403`, read `podman logs systemd-forgejomcp` for
the `Host` it refused and add that string to `FORGEJO_MCP_ALLOWED_HOSTS`; nothing
else in the route needs to change.

## Networking and ports

All containers join `systemd-devnetng` (from `devnetng.network`). Host ports are
bound to loopback only unless [Reaching the stack from another
machine](#reaching-the-stack-from-another-machine) says otherwise.

| Container port | Host binding | Reachable from a remote client |
|---|---|---|
| 5432 (PostgreSQL) | `127.0.0.1:5432`, `[::1]:5432` | via tunnel or private network, directly |
| 6379 (Valkey) | `127.0.0.1:6379`, `[::1]:6379` | via tunnel or private network, directly |
| 38080 (gateway UI) | `127.0.0.1:38080`, `[::1]:38080` | **loopback only, by design** — it mints virtual keys and edits routes; reach it through a tunnel |
| 4000 (gateway LLM + GitHub/Playwright/Forgejo MCP) | `127.0.0.1:4000`, `[::1]:4000` | via tunnel or private network; `/v1` is key-gated (`mode: strict`), MCP routes carry their own tokens |
| 8931 (Playwright MCP) | not published — gateway route only | through `/mcp/playwright` |
| 8080 (Forgejo MCP) | not published — gateway route only | through `/mcp/forgejo`, with your own Forgejo token |

Inside the network, the container names are the hostnames: `systemd-postgres`,
`systemd-valkey`, `systemd-agentgateway`, `systemd-playwrightmcp`,
`systemd-forgejomcp`. Quadlet prefixes `systemd-`; using the unit's own name
(`postgres`) resolves to nothing.

`TODO:` add a diagram.

### Verify a fresh install

These run on the host itself, so they address `127.0.0.1`; from a dev machine
substitute the name you reach the host by. Two of them are meant to be refusals —
there is no virtual key yet and the dashboard wants basic auth — and the last two
answer `200` on a real MCP handshake:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/v1/models   # 401: no virtual key yet
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:38080/           # 401 without basic auth
curl -sS -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer $DOWNSTREAM_GITHUB_MCP_TOKEN" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -X POST http://127.0.0.1:4000/mcp/github -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
# Served through /mcp/forgejo, but the token is your Forgejo one, not a gateway token:
curl -sS -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer $FORGEJO_USER_TOKEN" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -X POST http://127.0.0.1:4000/mcp/forgejo -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
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
| A unit silently fails to generate | Unsupported key in the unit, or an `Image=`/`Network=` naming a quadlet that is not in `installed/quadlets/`; the generator refuses to translate a missing dependency |
| Volumes point at an empty directory, or at a path that does not exist | `installed/` was never seeded, or the tree moved after seeding; re-run `./scripts/setup.sh` and read its `differs` lines |
| Gateway returns 401 | `DOWNSTREAM_*_TOKEN` mismatch between the client and `installed/envars/agentgateway.env` |
| Gateway returns 403/404 on `/mcp/playwright` | The route did not load — check the gateway log for a config error; the whole gateway fails rather than one route |
| `systemd-forgejomcp` restarts every 30s | `installed/envars/forgejomcp.env` still holds a seed placeholder, or `FORGEJO_URL` is unreachable from the container. Check `podman logs systemd-forgejomcp`; the unit exits rather than serving when it cannot reach Forgejo |
| Forgejo MCP returns 403 | The `Host` header the gateway sends (`systemd-forgejomcp:8080`) is not in `FORGEJO_MCP_ALLOWED_HOSTS`; entries match by host with no wildcard, and a 403 logs the header it refused |
| Forgejo MCP returns 401 | `FORGEJO_MCP_ALLOW_OPERATOR_TOKEN_FALLBACK=0` and the request carried no `Authorization` header — that is the intended answer, send your own token |
| Unit starts at boot but nothing answers | The user manager is not lingering: `loginctl enable-linger $USER` |
| Screenshots not visible on this host | They are written to `installed/data/playwrightmcp/` on the *infrastructure* host, owned by a mapped subuid; copy them across, they are world-readable |

`TODO:` add log locations and a reset procedure.

## Security notes

- `installed/` is gitignored as a whole, so no tracked file holds a secret: the
  units systemd loads, the env files with real keys and the container state all
  live there. `skel/` is tracked, ships placeholders only, and seeds that tree.
- Every published port is on loopback by default, and 38080 stays on loopback:
  it can mint virtual keys and rewrite routes, and HTTP basic auth is all it has.
- The LLM listener is fail-closed, not open: `mode: strict` with an empty key list
  admits nobody until a virtual key exists, and then admits only valid keys. What
  would spend your provider keys for anyone who asks is `mode: optional` (the
  gateway's default when `mode` is omitted) or `permissive`, or no `apiKey`
  policy at all.
- The gateway admin UI is protected by HTTP basic auth; keep it on loopback.
- `GITHUB_MCP_PAT` is intended to be read-only; write tools will fail with 403.
- `FORGEJO_ACCESS_TOKEN` is not served to headerless requests here
  (`FORGEJO_MCP_ALLOW_OPERATOR_TOKEN_FALLBACK=0`), and that matters more now than
  it did when the MCP port was published: the gateway forwards whatever
  `Authorization` header it was given, so fallback-on would hand the operator's
  Forgejo identity to any client that reached the route.
- Forgejo MCP is not published either, and its route adds no credential of its
  own — the token on it is the client's Forgejo token. Anyone who can reach
  port 4000 can reach the server, and gets `401` without a token.
- Playwright is not published: anything on `devnetng` that can reach 8931 can
  drive a browser with whatever credentials that browser can hold, and the
  container runs with `--allowed-hosts "*"`. It is served over the gateway so a
  client outside the network needs a bearer token to get there.
- Env files created by `scripts/setup.sh` under `installed/envars/` are chmod
  `600`, since they are where the API keys and proxy tokens end up. The tracked
  seeds next to them are placeholders and hold no credential.
- Both stacks on one host is not a supported layout: the unit names, the network
  name and the loopback ports would collide. Run one.

## Roadmap / TODO

- [ ] Virtual keys as a tracked procedure rather than a dashboard step: which key
      belongs to which environment, and when it was last rotated (minting them
      works today — see [Virtual keys](#virtual-keys-llm-access))
- [ ] Per-client `DOWNSTREAM_*` tokens instead of one shared value per route
- [ ] A gateway-side credential for `/mcp/forgejo`, if one is ever wanted: it has
      to arrive in a header of its own (checked by `authorization`, then removed
      by `requestHeaderModifier`), because `Authorization` on that route belongs
      to the client's Forgejo identity
- [x] Per-host overrides — `installed/quadlets/`, `installed/envars/` and
      `installed/data/` are this host's, and a pull never overwrites them
- [ ] `Makefile` / `justfile` for build, install and teardown
- [ ] Validate envars before starting units
- [ ] Health checks for postgres/valkey/gateway
- [ ] Document the agent gateway routes and policies in detail
- [ ] Add backups for `installed/data/postgres`
