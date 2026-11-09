# AGENTS.md

Repository-specific guidance for coding agents. Read this before changing
anything; it covers invariants that are easy to break silently.

## What this is

The infrastructure half of devstack, defined entirely as Quadlet units in
`skel/quadlets/`: PostgreSQL + PostGIS + pgvector, Valkey, the agent gateway, the
Playwright MCP browser and the Forgejo MCP server, on one bridge network. No
development environment ships here — no `fakevm` container, no image build that
provisions a user — and no client configs either; those live with the client.

Two trees matter, and the distinction is the whole design:

- **`skel/`** is tracked, and is a mirror of what a running install needs:
  `skel/quadlets/`, `skel/envars/`, `skel/data/`. The files carry the names they
  will have once installed, not `*.example` names, because a deployment fills
  them in under `installed/` and never in place.
- **`installed/`** is gitignored and belongs to this machine: the units systemd
  loads, the env files holding real keys, the container state. Seeded from
  `skel/` by `scripts/setup.sh`, edited there afterwards.

That split is why `git pull` and `git status` stay usable on a host that has
tuned its units: a deployment edit touches an ignored copy, and a pull changes
only the seed.

A root `install.sh` runs three scripted steps in order, and a fourth script
manages the units afterwards:

- `install.sh` — the entry point: runs the three below, and stops at the first
  one that fails.
- `scripts/pre-setup.sh` — downloads the one build input git cannot carry, the
  forgejo-mcp release bundles, verifies each against a pinned sha256, and skips
  anything already present.
- `scripts/setup.sh` — seeds `installed/` from `skel/`, substitutes
  `@REPO_ROOT@`, creates the empty runtime directories, and reports seeds that
  disagree with the install.
- `scripts/link-quadlets.sh` — symlinks `installed/quadlets/` into the rootless
  Quadlet search path.
- `scripts/manage-stack.sh` — starts/stops the units and prints where they are.

## Invariants

1. **Never commit a secret.** `installed/` is the only ignored tree, and it is
   where credentials end up: env files with real keys, a configured gateway, the
   container state. `skel/` is tracked, so a seed may ship a credential's *name*
   and never a value — `skel/envars/*.env` is a tracked file, and a real key
   pasted into it is a committed secret even though the copy in `installed/envars/`
   is the one in use.
   `builds/forgejomcp/binaries/` is ignored for a licence reason, not a secrecy
   one: it is upstream GPL object code, and committing it makes this repository
   its distributor (see `THIRD-PARTY.md`).
2. **Empty directories come from `DIRS`, and `DIRS` is load-bearing.** Nothing
   ignored can be recreated by git, so a `.gitkeep` would itself be ignored;
   `scripts/setup.sh` makes `installed/data/{playwrightmcp,postgres,valkey}` from
   its `DIRS` array instead. **Removing a directory from this repository means
   removing it from `DIRS` too**, or the next install run recreates it — that is
   how a removed directory comes back.
3. **`scripts/setup.sh` never overwrites.** Skipping an existing file is
   deliberate: `installed/quadlets/` is where a unit gets tuned for a host,
   `installed/envars/*.env` holds the real keys, and
   `installed/data/agentgateway/config.yaml` is a configured gateway. Do not "fix"
   this into a copy-if-different. The drift report at the end of the run is what
   keeps the other half visible: a pull changes `skel/` and does **not** reach
   `installed/` on its own.
4. **No unit hardcodes a host path.** `skel/quadlets/` carries `@REPO_ROOT@` where
   the checkout's absolute path belongs, and `scripts/setup.sh` substitutes it
   while seeding, so the stack works wherever the tree is cloned. Do not
   reintroduce `%h/Containers/devinfra`: systemd would expand `%h` and hide the
   assumption again. `@REPO_ROOT@` is chosen because neither systemd nor podman
   expands it — an unsubstituted one leaves a path that plainly does not exist
   instead of one that quietly resolves somewhere else. Because the path is baked
   at seed time, `link-quadlets.sh` needs no expected root and has no mismatch to
   report; do not add that check back.
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

   Widening a port is a deployment decision, not a change to this repository: the
   tracked `skel/quadlets/` is the reviewed default and stays loopback, while
   `installed/quadlets/` — which git never sees — is where a host binds another
   interface. Invariant 8 is what makes that safe for 4000. Publishing the
   dashboard, the browser or Postgres is not a deployment choice.
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
   seed ships `llm.policies.apiKey` as `mode: strict` with `keys: []`, which is
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
- Every host path goes through the token: `EnvironmentFile=@REPO_ROOT@/installed/envars/<name>.env`,
  `Volume=@REPO_ROOT@/installed/data/<dir>:<container-path>`, and
  `SetWorkingDirectory=@REPO_ROOT@/builds/<image>` for a `.build` unit. See
  invariant 4; `skel/quadlets/README` explains it to a reader of the units.
- **Unknown keys make the unit silently fail to generate.** `Tty=` and
  `Systemd=` do not exist; use `PodmanArgs=` if you truly need one.
- Do not add `RunInit=` to `forgejomcp.container`: the image already runs
  catatonit as PID 1, so `podman --init` would put a second init ahead of it.
- `forgejomcp.container` has no dependency ordering on purpose: it dials
  `FORGEJO_URL` and exits non-zero when it cannot reach it, so with the
  `skel/envars/forgejomcp.env` seed in place it restarts every `RestartSec` while
  the rest of the stack runs. That is the intended failure mode; do not "fix" it
  by adding it to anything else's `Wants=`.
- Nothing here is a PID-1 systemd container, so `RunInit=` is fine on
  `agentgateway` and `playwrightmcp` and is what they already do.

## Common tasks

**Add an env var** — add it to the seed in `skel/envars/<file>.env`, to the table
in `README.md`, and to the unit in `skel/quadlets/` that consumes it if it is new.
An existing `installed/envars/<file>.env` is never overwritten, so say in the
commit that an installed host has to add the value by hand.

**Add a container unit** — drop a `.container` into `skel/quadlets/`;
`scripts/setup.sh` seeds it into `installed/quadlets/` and
`scripts/link-quadlets.sh` picks it up by extension. Add its name to `UNITS` in
`scripts/manage-stack.sh` and to the endpoints it prints, record it in `README.md`'s
component and port tables, and add any new host directory to `DIRS` in
`scripts/setup.sh` — under `installed/data/`, since that is where a unit mounts
from.

**Add a gateway route** — `skel/data/agentgateway/config.yaml`, a
`DOWNSTREAM_*TOKEN` in `skel/envars/agentgateway.env`, a row in the README table,
and a header for it in the client's own config, which lives outside this
repository. Mirror an existing route rather than inventing a shape: `pathPrefix`
+ `urlRewrite.full: /mcp/` for streamable HTTP (see `playwright-mcp-proxy`), which
unlike the GitHub route has no `method:` because streamable HTTP also uses GET and
DELETE. `forgejo-mcp-proxy`
is the one route with **no** token and **no** `authorization` policy: its
`Authorization` header belongs to the client's Forgejo identity and is forwarded
verbatim, so do not add a `DOWNSTREAM_*` check there — see invariant 5.

**Change a port** — three places move together for the default: the unit in
`skel/quadlets/`, the README port table, and the endpoint block in
`scripts/manage-stack.sh`. A host that has already run `setup.sh` also has its own
copy in `installed/quadlets/` to edit, which is the deployment edit invariant 5
allows.

**Bump forgejo-mcp** — three places move together, and a miss fails the build
rather than shipping something unexpected: the `FORGEJO_MCP_VERSION` ARG in
`builds/forgejomcp/Containerfile`, and `FORGEJO_MCP_VERSION` plus both sha256
pins in `scripts/pre-setup.sh`, taken from the new release's
`forgejo-mcp_<version>_checksums.txt`. Bump `THIRD-PARTY.md` too, which names the
version, the licence and the source tag.

**Add or swap a model** — three files move together: the model entry and its rates
under `config.modelCatalog` in `skel/data/agentgateway/config.yaml`, the provider's
API key in `skel/envars/agentgateway.env`, and the env var row in `README.md`.
That catalog is the only copy of the rates now that client configs live outside
this repository, and a model without rates still serves requests while quietly
dropping out of the cost estimate — add them in the same commit.

**Reset the stack's state** — `rm -rf installed/` then `./scripts/setup.sh`. That
deletes the database, the gateway's SQLite history, every seeded unit and env
file; nothing tracked is touched, which is the point of the split. `git clean
-fdx` does the same and is safe here for the same reason — but it also removes
`builds/forgejomcp/binaries/`, which then has to be fetched again.

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

`scripts/setup.sh` writes only inside the checkout and is idempotent. Run it
twice against a throwaway copy of the repository: the second run must copy
nothing and report no drift. Any `differs` line on an untouched install is a
substitution bug, not a local edit.

A fresh seed must leave no placeholder behind — this is the check that catches a
seed whose path the substitution missed:

```bash
grep -rn '@REPO_ROOT@' installed/quadlets/ || echo 'all substituted'
```

`scripts/link-quadlets.sh` needs `installed/quadlets/` to exist, so seed first,
and note that it writes into `$XDG_CONFIG_HOME` (default `$HOME/.config`).
Exercise it against a throwaway home instead of the real one:

```bash
HOME=/tmp/fake ./scripts/link-quadlets.sh
HOME=/tmp/fake XDG_CONFIG_HOME=/tmp/fake/xdg ./scripts/link-quadlets.sh
```

`scripts/manage-stack.sh` needs a user manager, which a dev shell may not have.
Stub `systemctl` on `$PATH` to exercise its argument handling — a fake that
answers `cat`, `show`, `is-enabled` and logs `start`/`stop` is enough — and check
that the unit list matches `skel/quadlets/`.

The Quadlet generator is the only authority on whether a unit is valid. `podman`
may not be installed (it is not in the base dev shell); when it is, point it at
the seeded copy rather than the seeds, because those still carry the token:

```bash
./scripts/setup.sh
QUADLET_UNIT_DIRS=installed/quadlets /usr/lib/systemd/system-generators/podman-system-generator --user --dryrun
```

Read the generated `ExecStart=` rather than trusting the unit file: it is the
only way to confirm that `Volume=` options survived as one `-v` argument, that
the absolute path arrived, and that `[Install]` was carried through (`systemctl
--user enable` fails without it).

The gateway config is YAML with a schema this repo cannot check, so at minimum
parse it before committing a change:

```bash
node -e 'process.stdout.write(JSON.stringify(require("yaml").parse(
  require("fs").readFileSync("skel/data/agentgateway/config.yaml","utf8")),null,1))' \
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

- Editing `installed/quadlets/` needs only `systemctl --user daemon-reload`: the
  search path holds symlinks, so changes are live without reinstalling. Editing
  `skel/quadlets/` changes nothing until `setup.sh` seeds it and the existing
  copy is removed or updated by hand.
- `scripts/setup.sh` chmods `600` only the files it creates. An
  `installed/envars/*.env` created by hand keeps its own mode, and a seeded one
  keeps `600` from then on.
- A `git pull` that changes a seed does not reach an installed host. The drift
  report names it; the merge is manual and stays manual.
- devstack and this repository cannot run on the same host: same unit names, same
  network name, same loopback ports.
