#!/usr/bin/env bash
#
# scripts/manage-stack.sh -- start, stop and inspect the infrastructure stack.
#
# Why this exists: in devstack, fakevm.container carried `Wants=` for every other
# unit, so `systemctl --user start fakevm.service` was the one command that
# brought the stack up. This checkout has no VM to hang that off, and adding
# cross-unit dependencies here would make a bounce of postgres a bounce of the
# gateway. So the start order lives in one place, deliberately outside systemd:
# this script starts the units in a single transaction, and nothing else depends
# on anything.
#
# It starts units; it does not enable them. `up` is for a session, `systemctl
# --user enable <unit>` (the units carry [Install] WantedBy=default.target) is
# for a machine that should come back up serving after a reboot. Doing the second
# by accident is unpleasant -- a host whose only purpose was a quick test starts
# pulling images and holding ports on every boot -- so it is a separate,
# explicit act.
#
# Nothing here is destructive and nothing needs root: stopping a unit leaves its
# installed/data/ directory alone.

set -e
set -u
set -o pipefail

# Resolve through symlinks, so a copy on $PATH behaves like ./scripts/….
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Service names, in start order. Quadlet generates <name>.service from
# installed/quadlets/<name>.container -- the copy seeded from skel/, which is the
# one link-quadlets.sh links and the one a deployment may have tuned; the .build
# units are pulled in by `Image=` on the containers that need them, and
# devnetng.network by `Network=`, so neither is listed here.
UNITS=(
  postgres
  valkey
  agentgateway
  playwrightmcp
  forgejomcp
)

# check to see if this file is being run or sourced from another script
_is_sourced() {
  # https://unix.stackexchange.com/a/215279
  [ "${#FUNCNAME[@]}" -ge 2 ] \
    && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
    && [ "${FUNCNAME[1]}" = 'source' ]
}

_usage() {
  cat <<'EOF'
usage: manage-stack.sh {up|down|restart|status}

  up       start every unit, in order, in one transaction
  down     stop them again, in reverse order
  restart  down, then up
  status   per-unit active and enabled state, plus the endpoints

Starting is not enabling: units come back after a reboot only once they are
enabled (`systemctl --user enable postgres.service …`, see README).
EOF
}

# Quadlet units only exist for systemd once they have been linked into the search
# path and the user manager has been reloaded. Checking first turns "Unit
# postgres.service not found" -- which says nothing about the fix -- into one
# line naming it.
_requiring_installed_units() {
  local unit

  for unit in "${UNITS[@]}"; do
    if ! systemctl --user cat "$unit.service" >/dev/null 2>&1; then
      printf 'error: %s.service is not installed\n' "$unit" >&2
      printf '       run ./scripts/link-quadlets.sh && systemctl --user daemon-reload\n' >&2
      exit 1
    fi
  done
}

_starting() {
  local unit
  local -a services=()

  for unit in "${UNITS[@]}"; do
    services+=("$unit.service")
  done

  # One transaction, so a failure in the middle is reported against the unit that
  # failed rather than leaving the caller to work out where the loop stopped.
  printf 'starting  %s\n' "${UNITS[*]}"
  systemctl --user start "${services[@]}"
}

_stopping() {
  local -a services=()
  local list unit

  # Reverse order: the units have no dependencies on each other, so this is only
  # for a log that reads top-down against the start order.
  for unit in $(printf '%s\n' "${UNITS[@]}" | tac); do
    services+=("$unit.service")
  done

  list="$(printf '%s\n' "${UNITS[@]}" | tac | tr '\n' ' ')"
  printf 'stopping  %s\n' "${list% }"
  systemctl --user stop "${services[@]}"
}

_printing_status() {
  local unit state enabled

  printf '%-16s %-12s %s\n' UNIT ACTIVE ENABLED
  for unit in "${UNITS[@]}"; do
    state="$(systemctl --user show -p ActiveState --value "$unit.service" 2>/dev/null || true)"
    enabled="$(systemctl --user is-enabled "$unit.service" 2>/dev/null || true)"
    printf '%-16s %-12s %s\n' "$unit" "${state:-unknown}" "${enabled:-unknown}"
  done
}

_printing_endpoints() {
  cat <<'EOF'

on this host (loopback):
  PostgreSQL          postgresql://postgres:<password>@127.0.0.1:5432/postgres
  Valkey              redis://127.0.0.1:6379
  Gateway admin UI    http://127.0.0.1:38080 (HTTP basic auth; loopback only -- it mints virtual keys)
  Gateway API         http://127.0.0.1:4000/v1        (LLM, needs a virtual key: mode strict)
  GitHub MCP proxy    http://127.0.0.1:4000/mcp/github   (Bearer DOWNSTREAM_GITHUB_MCP_TOKEN)
  Playwright MCP      http://127.0.0.1:4000/mcp/playwright (Bearer DOWNSTREAM_PLAYWRIGHT_MCP_TOKEN)
  Forgejo MCP         http://127.0.0.1:4000/mcp/forgejo  (Bearer <your own Forgejo token>)

on devnetng, container to container only (not published):
  Postgres  systemd-postgres:5432      Valkey  systemd-valkey:6379
  Gateway   systemd-agentgateway:4000  Playwright  systemd-playwrightmcp:8931
  Forgejo   systemd-forgejomcp:8080

Client configs for another machine: clients/pi/ (see README).
EOF
}

_parsing_args() {
  case "${1:-}" in
    up|down|restart|status) ;;
    -h|--help)
      _usage
      exit 0
      ;;
    '')
      printf 'error: no command\n\n' >&2
      _usage >&2
      exit 1
      ;;
    *)
      printf 'error: unknown command %s\n\n' "$1" >&2
      _usage >&2
      exit 1
      ;;
  esac
}

_main() {
  local command="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'error: systemctl not found; the units are systemd user units\n' >&2
    exit 1
  fi

  if [[ $command != status ]]; then
    _requiring_installed_units
  fi

  case "$command" in
    up)
      _starting
      printf '\n'
      _printing_status
      _printing_endpoints
      ;;
    down)
      _stopping
      printf '\n'
      _printing_status
      ;;
    restart)
      _stopping
      _starting
      printf '\n'
      _printing_status
      ;;
    status)
      _printing_status
      _printing_endpoints
      ;;
  esac
}

if ! _is_sourced; then
  _parsing_args "$@"
  _main "$@"
fi
