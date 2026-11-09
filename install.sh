#!/usr/bin/env bash
#
# install.sh -- prepare this checkout, in one command.
#
# The work is in scripts/, one script per concern, and this runs them in the
# only order that works. It is deliberately not named setup.sh: one of the three
# steps is scripts/setup.sh, and a root setup.sh next to it looked like the same
# thing twice.
#
#   scripts/pre-setup.sh      fetch the forgejo-mcp release bundles. A build
#                             input, and the only step that needs the network.
#   scripts/setup.sh          seed installed/ from skel/: the units, the
#                             environment files and the container state this
#                             machine runs on.
#   scripts/link-quadlets.sh  symlink installed/quadlets/ into the rootless
#                             Quadlet search path. What makes the units visible
#                             to systemd at all.
#
# All three are idempotent and none of them overwrites: re-running this costs a
# stat per directory and a check for missing bundles, and nothing more.
#
# Deliberately not included: `systemctl --user daemon-reload`. That talks to the
# running user manager rather than changing the checkout, it fails on a machine
# where no user session exists, and link-quadlets.sh ends by printing it. Run it
# yourself once this has finished.
#
# Usage:
#   ./install.sh              # this host's architecture, one bundle
#   ./install.sh --all-arch   # both bundles, for a cross build

set -e
set -u
set -o pipefail

# Resolve through symlinks: this script is at the repository root, and the three
# steps are called by absolute path so that a $PATH or symlinked invocation
# behaves the same as ./install.sh.
REPO_ROOT="$(dirname "$(realpath "$0")")"

# Arguments for scripts/pre-setup.sh. Kept separate so that --all-arch reaches
# the one step it means something to, instead of being sprayed at all three.
PRE_SETUP_ARGS=()

# check to see if this file is being run or sourced from another script
_is_sourced() {
  # https://unix.stackexchange.com/a/215279
  [ "${#FUNCNAME[@]}" -ge 2 ] \
    && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
    && [ "${FUNCNAME[1]}" = 'source' ]
}

_usage() {
  cat <<'EOF'
usage: install.sh [--all-arch]

Prepare the checkout: fetch the forgejo-mcp release bundles, seed installed/
from skel/, then link the units into the rootless Quadlet search path.

  --all-arch   fetch every pinned architecture instead of only this host's
  -h, --help   this text
EOF
}

_parsing_args() {
  while (($# > 0)); do
    case "$1" in
      --all-arch)
        PRE_SETUP_ARGS+=(--all-arch)
        ;;
      -h|--help)
        _usage
        exit 0
        ;;
      *)
        printf 'error: unknown argument %s\n\n' "$1" >&2
        _usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

# Announced before the step runs, so that a bare exit status further down still
# names the step that produced it.
_running_step() {
  local script="$1"
  shift

  printf '\n==> %s\n' "${script#"$REPO_ROOT"/}"
  if ! "$script" "$@"; then
    printf 'error: %s failed; stopping\n' "${script#"$REPO_ROOT"/}" >&2
    exit 1
  fi
}

_main() {
  _parsing_args "$@"

  _running_step "$REPO_ROOT/scripts/pre-setup.sh" "${PRE_SETUP_ARGS[@]}"
  _running_step "$REPO_ROOT/scripts/setup.sh"
  # link-quadlets.sh prints the daemon-reload reminder itself; do not repeat it.
  _running_step "$REPO_ROOT/scripts/link-quadlets.sh"

  printf '\nnext: fill in installed/envars/*.env and\n'
  printf '      installed/data/agentgateway/config.yaml, then\n'
  printf '      ./scripts/manage-stack.sh up\n'
}

if ! _is_sourced; then
  _main "$@"
fi
