# AGENTS.md

Repository-specific guidance for coding agents. Read this before changing
anything; it covers invariants that are easy to break silently.

## What this is

The infrastructure half of devstack, defined entirely as Quadlet units in
`quadlets/`: PostgreSQL + PostGIS + pgvector, Valkey, the agent gateway, the
Playwright MCP browser and the Forgejo MCP server, on one bridge network. No
development environment ships here — no `fakevm` container, no image build that
provisions a user, no `skel/`. Client-side configs live in `clients/pi/` as
templates only.

A root `install.sh` runs three scripted steps in order, and a fourth script
manages the units afterwards:

- `install.sh` — the entry point: runs the three below, and stops at the first
  one that fails.
- `scripts/pre-setup.sh` — downloads the one build input git cannot carry, the
  forgejo-mcp release bundles, verifies each against a pinned sha256, and skips
  anything already present.
- `scripts/setup.sh` — rebuilds the gitignored tree: directories and
  `*.example` → real files.
- `scripts/link-quadlets.sh` — symlinks `quadlets/` into the rootless Quadlet
  search path and warns if the checkout is not where the units expect it.
- `scripts/manage-stack.sh` — starts/stops the units and prints where they are.

## Invariants

1. **Never commit a secret.** `data/**`, `envars/**` and `clients/**` are
   gitignored except `*.example` templates. Tracked files must never contain a
   credential — new config belongs in a `*.example` template.
   `builds/forgejomcp/binaries/` is ignored for a licence reason, not a secrecy
   one: it is upstream GPL object code, and committing it makes this repository
   its distributor (see `THIRD-PARTY.md`).
2. **`.gitkeep` cannot solve an empty directory here.** The ignore rules match
   everything but `*.example`, so a placeholder file is itself ignored.
   Directories are recreated by `scripts/setup.sh`; add new ones to its `DIRS`
   array.
3. **`scripts/setup.sh` never overwrites.** Skipping an existing file is
   deliberate: the destination may hold real credentials (`envars/*.env`), a
   configured gateway (`data/agentgateway/config.yaml`) or a filled-in client
   config. Do not "fix" this into a copy-if-different.
4. **Quadlets hardcode host paths as `%h/Containers/devinfra/...`.** The stack
   only works if the checkout is there. `scripts/link-quadlets.sh` derives that
   root from the unit contents and compares it to the real location — keep that
   check working if you add paths.
5. **Exposure is decided per unit, and three rules are load-bearing:**
   - every `PublishPort=` binds loopback (`127.0.0.1` / `[::1]`), one line per
     address family;
   - `playwrightmcp.container` publishes nothing, ever. The browser has no
     authentication and runs with `--allowed-hosts "*"`; it is served through the
     gateway's `/mcp/playwright` route instead;
   - `forgejomcp.container` publishes nothing, and is served through the
     gateway's `/mcp/forgejo` route. That route has no `authorization` policy on
     purpose: `forgejo-mcp` reads `Authorization` and forwards it to Forgejo, so
     the bearer there is the client's own Forgejo token and one-per-environment
     identity is the point. A `require` on that header would need one fixed
     token, and the only fixed one available is the operator's
     (`FORGEJO_ACCESS_TOKEN`) — which is why
     `FORGEJO_MCP_ALLOW_OPERATOR_TOKEN_FALLBACK=0` stays: fallback on plus a
     gateway that forwards whatever header it was given serves headerless
     requests as the operator. devstack has fallback on and no gateway, which is
     the same rule from the other side.
6. **`[Install] WantedBy=default.target` is intentional here, and absent in
   devstack.** There the stack hangs off a disposable VM and must not start at
   boot; here the stack is infrastructure on a host that may be shared. Starting
   (`manage-stack.sh up`) and enabling (`systemctl --user enable`) stay separate
   so trying the stack out does not make it permanent.
7. **No cross-unit `Wants=`/`Requires=` in this stack.** devstack anchors the
   whole set on `fakevm.container`; here the start order lives in
   `scripts/manage-stack.sh`. Adding a dependency would make a bounce of postgres
   a bounce of the gateway, which is the opposite of what a shared host wants.
   `.build` and `.network` units are pulled in by `Image=`/`Network=` and need no
   dependency of their own.
8. **The LLM listener is key-gated, and `mode: strict` is what keeps it so.** The
   template ships `llm.policies.apiKey` as `mode: strict` with `keys: []`, which is
   fail-closed: strict requires a valid key and an empty list admits none, so every
   `/v1` request is refused until an operator creates a virtual key — hashed, at
   runtime, through the dashboard. Publishing port 4000 on another interface is
   therefore a normal decision, not a keys-first one. **`mode: optional` (the
   gateway's default when `mode` is omitted), `permissive`, or no `apiKey` policy
   at all must never ship**: those admit keyless requests, and only then does "can
   reach 4000" mean "can spend the provider keys". Port 38080 stays loopback in
   every shape — it mints those keys and edits routes, so it is the one port whose
   exposure would undo the rest.

## Quadlet conventions

Copy the shape of the existing units:

```ini
[Unit]
Description=…

[Container]
Image=…
Network=devnetng.network
PublishPort=127.0.0.1:<port>:<port>/tcp
PublishPort=[::1]:<port>:<port>/tcp

[Install]
WantedBy=default.target

[Service]
Restart=on-failure
RestartSec=30s
```

- Reference `.build` units from `Image=` (e.g. `Image=forgejomcp.build`) and other
  Quadlets by **filename** in dependency keys (`postgres.container`), never by
  `.service`. Quadlet rewrites the name at generation time; hand-written
  `.service` names bypass that and break under `ServiceName=`.
- **Unknown keys make the unit silently fail to generate.** `Tty=` and
  `Systemd=` do not exist; use `PodmanArgs=` if you truly need one.
- Do not add `RunInit=` to `forgejomcp.container`: the image already runs
  catatonit as PID 1, so `podman --init` would put a second init ahead of it.
- `forgejomcp.container` has no dependency ordering on purpose: it dials
  `FORGEJO_URL` and exits non-zero when it cannot reach it, so with the
  `envars/forgejomcp.env` template in place it restarts every `RestartSec` while
  the rest of the stack runs. That is the intended failure mode; do not "fix" it
  by adding it to anything else's `Wants=`.
- Nothing here is a PID-1 systemd container, so `RunInit=` is fine on
  `agentgateway` and `playwrightmcp` and is what they already do.

## Common tasks

**Add an env var** — add it to the `*.example` template, to the table in
`README.md`, and to the unit that consumes it if it is new. If it is a
`DOWNSTREAM_*` token, add it to the matching `clients/pi/*.example` header too.
The real `envars/*.env` is gitignored and regenerated by `scripts/setup.sh`.

**Add a container unit** — drop a `.container` into `quadlets/`;
`scripts/link-quadlets.sh` picks it up by extension. Add its name to `UNITS` in
`scripts/manage-stack.sh` and to the endpoints it prints, record it in
`README.md`'s component and port tables, and add any new host directory to
`DIRS` in `scripts/setup.sh`.

**Add a gateway route** — `data/agentgateway/config.yaml.example`, a
`DOWNSTREAM_*TOKEN` in `envars/agentgateway.env.example`, a row in the README
table, and a header in `clients/pi/mcp.json.example`. Mirror an existing route
rather than inventing a shape: `pathPrefix` + `urlRewrite.full: /mcp/` for
streamable HTTP (see `playwright-mcp-proxy`), which unlike the GitHub route has
no `method:` because streamable HTTP also uses GET and DELETE. `forgejo-mcp-proxy`
is the one route with **no** token and **no** `authorization` policy: its
`Authorization` header belongs to the client's Forgejo identity and is forwarded
verbatim, so do not add a `DOWNSTREAM_*` check there — see invariant 5.

**Change a port** — the unit, the README port table, and the endpoint block in
`scripts/manage-stack.sh` print the same number three times.

**Bump forgejo-mcp** — three places move together, and a miss fails the build
rather than shipping something unexpected: the `FORGEJO_MCP_VERSION` ARG in
`builds/forgejomcp/Containerfile`, and `FORGEJO_MCP_VERSION` plus both sha256
pins in `scripts/pre-setup.sh`, taken from the new release's
`forgejo-mcp_<version>_checksums.txt`. Bump `THIRD-PARTY.md` too, which names the
version, the licence and the source tag.

**Add or swap a model** — five files move together: the model entry in
`clients/pi/models.json.example`, its rates and `llm.models` route in
`data/agentgateway/config.yaml.example`, the provider's API key in
`envars/agentgateway.env.example`, and the env var row in `README.md`. The rate
table in the client and the catalog in the gateway are two copies of the same
numbers and nothing keeps them in sync.

**Reset the stack's state** — `rm -rf data/` then `./scripts/setup.sh`. That
deletes the database and the gateway's SQLite history; nothing else in the
checkout is affected.

## Verifying

Static checks, always valid:

```bash
for f in install.sh scripts/*.sh; do bash -n "$f"; done
```

Note that `bash -n a.sh b.sh` checks only `a.sh` — the second path is taken as a
positional parameter.

`scripts/pre-setup.sh` writes only inside the checkout and is idempotent, but it
reaches the network when a bundle is missing. Run it once with the bundles
present, and it should make no request at all.

`scripts/setup.sh` writes only inside the checkout and is idempotent.

`scripts/link-quadlets.sh` writes into `$XDG_CONFIG_HOME` (default
`$HOME/.config`), so exercise it against a throwaway home instead of the real
one:

```bash
HOME=/tmp/fake ./scripts/link-quadlets.sh
HOME=/tmp/fake XDG_CONFIG_HOME=/tmp/fake/xdg ./scripts/link-quadlets.sh
```

`scripts/manage-stack.sh` needs a user manager, which a dev shell may not have.
Stub `systemctl` on `$PATH` to exercise its argument handling — a fake that
answers `cat`, `show`, `is-enabled` and logs `start`/`stop` is enough — and check
that the unit list matches `quadlets/`.

The Quadlet generator is the only authority on whether a unit is valid. `podman`
may not be installed (it is not in the base dev shell); when it is:

```bash
QUADLET_UNIT_DIRS=quadlets /usr/lib/systemd/system-generators/podman-system-generator --user --dryrun
```

Read the generated `ExecStart=` rather than trusting the unit file: it is the
only way to confirm that `Volume=` options survived as one `-v` argument, that
`%h` expanded, and that `[Install]` was carried through (`systemctl --user
enable` fails without it).

The gateway config is YAML with a schema this repo cannot check, so at minimum
parse it before committing a change:

```bash
node -e 'process.stdout.write(JSON.stringify(require("yaml").parse(
  require("fs").readFileSync("data/agentgateway/config.yaml.example","utf8")),null,1))' \
  | head -40
```

## Script conventions

`install.sh`, `scripts/setup.sh`, `scripts/pre-setup.sh`,
`scripts/link-quadlets.sh` and `scripts/manage-stack.sh` follow the same shape:

- `set -e`, `set -u`, `set -o pipefail` at the top
- constants above functions
- `_is_sourced()` guard, `_`-prefixed helpers, `_main "$@"` called at the very
  bottom so the whole file parses before anything executes
- tallies are globals mutated by helpers; if you iterate with a pipe
  (`find … | while`) the loop runs in a subshell and the counts stay zero — use
  `while … done < <(…)`

## Traps

- Editing `quadlets/` needs only `systemctl --user daemon-reload`: the search
  path holds symlinks, so changes are live without reinstalling.
- `scripts/setup.sh` chmods `600` only the files it creates. An `envars/*.env` created
  by hand keeps its own mode.
- devstack and this repository cannot run on the same host: same unit names, same
  network name, same loopback ports.
