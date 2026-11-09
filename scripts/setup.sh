#!/usr/bin/env bash
#
# scripts/setup.sh -- rebuild devinfra's local tree from a fresh checkout.
#
# Why this exists: git tracks files, never directories, and most of what this
# project needs on disk is gitignored. Every directory listed below is either
# empty in a fresh checkout or holds only ignored content (runtime state,
# generated secrets), so none of them survive a clone or pull. Podman refuses to
# start a container whose bind-mount source does not exist, and Quadlet units
# fail the same way.
#
# A .gitkeep cannot solve this: data/** and envars/** ignore every path except
# *.example templates, so a placeholder file would not be tracked.
#
# This script does two things, in order:
#   1. creates the directory tree;
#   2. copies every *.example file to its name without the .example suffix.
#
# Two rules keep it safe to re-run on a live tree:
#   * it never overwrites a file that already exists -- an envars/*.env holding
#     real credentials is left alone, and so is a filled-in gateway config;
#   * it never deletes anything.
#
# Unlike devstack's setup.sh there are no SSH host keys to generate: nothing in
# this stack is an SSH server. The addresses clients use are plain TCP endpoints,
# so a fresh host has no per-host identity to bake in.
#
# Everything runs from _main, called at the very bottom, so the whole file is
# parsed before any command executes. Being parsed first is what makes a
# truncated checkout or a syntax error harmless, and it means the helpers can be
# sourced on their own without side effects.
#
# Paths resolve relative to this script's parent -- the repository root -- not
# to $HOME, so the checkout may live anywhere. Note that quadlets/*.container
# hard-code %h/Containers/devinfra/... -- if the tree is not checked out there,
# those units need adjusting on their own; this script does not do that.

# Exit immediately on errors
set -e
set -u
set -o pipefail

# Resolve through symlinks, so the script behaves the same whether it is called
# as ./scripts/setup.sh, ../../devinfra/scripts/setup.sh, or through a symlink on
# $PATH. REPO_ROOT is one level up from scripts/: everything below is a path
# inside the checkout, never inside scripts/.
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Every directory the tree needs, grouped by what consumes it.
DIRS=(
  # Quadlet bind-mount sources (quadlets/*.container)
  "data/agentgateway"            # agentgateway : /config -- config.yaml, model catalog, SQLite DBs
  "data/playwrightmcp"           # playwrightmcp: /mnt/playwrightmcp -- screenshots, downloads
  "data/postgres"                # postgres     : /var/lib/postgresql
  "data/valkey"                  # valkey       : /data

  # Build inputs
  "builds/postgisvec"            # Quadlet SetWorkingDirectory

  # Quadlet EnvironmentFile directory
  "envars"

  # Fill-in-then-copy client configs for an external dev environment
  "clients/pi"
)

# Run tallies, filled in by the helpers below and reported by _printing_summary.
DIRS_CREATED=0
EXAMPLES_COPIED=0
EXAMPLES_SKIPPED=0

# check to see if this file is being run or sourced from another script
_is_sourced() {
  # https://unix.stackexchange.com/a/215279
  [ "${#FUNCNAME[@]}" -ge 2 ] \
    && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
    && [ "${FUNCNAME[1]}" = 'source' ]
}

# 1. Directory tree
_creating_directory_tree() {
  local dir target

  for dir in "${DIRS[@]}"; do
    target="$REPO_ROOT/$dir"

    if [[ -d $target ]]; then
      continue
    fi

    mkdir -p "$target"
    printf 'created   dir   %s\n' "$dir"
    DIRS_CREATED=$((DIRS_CREATED + 1))
  done
}

# 2. *.example templates -> real files
#
# The destination is only written when absent. Never clobber envars/*.env, the
# gateway config or a client config: those hold configured credentials and
# one-off settings, and replacing them with template contents would silently
# discard them. Edit the result by hand afterwards.
_copying_example_files() {
  local src dest

  while IFS= read -r -d '' src; do
    dest="${src%.example}"

    if [[ -e $dest ]]; then
      EXAMPLES_SKIPPED=$((EXAMPLES_SKIPPED + 1))
      continue
    fi

    cp -- "$src" "$dest"

    # Files landing in envars/ are the ones that will hold real API keys and
    # generated tokens, and the templates ship world-readable (0644). Tighten
    # the copy to owner-only; sources for other locations keep their mode.
    if [[ $dest == "$REPO_ROOT"/envars/* ]]; then
      chmod 600 -- "$dest"
    fi

    printf 'created   file  %s\n' "${dest#"$REPO_ROOT"/}"
    EXAMPLES_COPIED=$((EXAMPLES_COPIED + 1))
  done < <(find "$REPO_ROOT" -type f -name '*.example' -not -path '*/.git/*' -print0 | sort -z)
}

_printing_summary() {
  printf '\n'
  printf 'directories  %d created, %d present\n' \
    "$DIRS_CREATED"      "$(( ${#DIRS[@]} - DIRS_CREATED ))"
  printf 'example files %d copied, %d already present\n' \
    "$EXAMPLES_COPIED"   "$EXAMPLES_SKIPPED"

  if (( EXAMPLES_COPIED > 0 )); then
    printf '\nTemplates were copied verbatim; replace the placeholder values before\n'
    printf 'starting the stack (envars/*.env, data/agentgateway/config.yaml and\n'
    printf 'data/agentgateway/agwadmins.htpasswd).\n'
  fi
}

_main() {
  _creating_directory_tree
  _copying_example_files
  _printing_summary
}

if ! _is_sourced; then
  _main "$@"
fi
