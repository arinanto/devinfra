#!/usr/bin/env bash
#
# scripts/setup.sh -- seed this machine's installed/ tree from skel/.
#
# Why this exists: a units-to-deployment mapping has to be editable without
# dirtying the checkout. Widening a published port, pointing a volume at another
# disk, filling in a key -- each of those is a local decision, and if it lives in
# a tracked file then `git pull` and `git status` both become arguments instead
# of tools. So the tracked copy is a seed and installed/ is the result:
#
#   skel/quadlets/  ->  installed/quadlets/   what link-quadlets.sh links
#   skel/envars/    ->  installed/envars/     what the units load
#   skel/data/      ->  installed/data/       what the units mount
#
# skel/ is laid out as a mirror of installed/, so seeding is a straight copy of
# one onto the other: no suffix to strip, no rename table to keep in sync. Only
# installed/ is gitignored, and git cannot recreate an ignored tree, so the empty
# runtime directories are made here from the DIRS list below.
#
# Two rules keep it safe to re-run on a live install:
#   * it never overwrites a file that already exists -- an installed/quadlets/
#     unit tuned for this host, an installed/envars/*.env holding real keys and a
#     filled-in gateway config all survive untouched;
#   * it never deletes anything.
#
# Not overwriting has one consequence worth stating: a `git pull` that changes
# skel/ does not reach installed/ by itself. _reporting_drift names every seed
# that disagrees with the install, so a pull is visible without being destructive.
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
# to $HOME, so the checkout may live anywhere. Note that skel/quadlets/*.container
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

# The seed tree and its destination, both resolved from the checkout.
SKEL_DIR="$REPO_ROOT/skel"
INSTALLED_DIR="$REPO_ROOT/installed"

# Every directory the install needs beyond the ones the seed copy creates, i.e.
# the empty runtime directories plus the one build input outside installed/.
DIRS=(
  # Quadlet bind-mount targets: empty by nature, nothing to seed them from
  "installed/data/playwrightmcp"  # playwrightmcp: /mnt/playwrightmcp -- screenshots, downloads
  "installed/data/postgres"       # postgres     : /var/lib/postgresql
  "installed/data/valkey"         # valkey       : /data

  # Build input
  "builds/postgisvec"             # Quadlet SetWorkingDirectory
)

# installed/quadlets, installed/envars and installed/data/agentgateway are
# absent from DIRS on purpose: _copying_seeds creates them with the files it
# puts there, and listing them twice would report them as already present.

# Run tallies, filled in by the helpers below and reported by _printing_summary.
DIRS_CREATED=0
SEEDS_COPIED=0
SEEDS_SKIPPED=0
SEEDS_DRIFTED=0

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

# 2. skel/ -> installed/
#
# The destination is only written when absent, because installed/ is where this
# machine's decisions live: a unit widened for the host, an env file with real
# keys, a filled-in gateway config. Seeding over them would discard exactly what
# the split exists to protect, so the copy is per file and never forced.
_copying_seeds() {
  local src rel dest

  while IFS= read -r -d '' src; do
    rel="${src#"$SKEL_DIR"/}"
    dest="$INSTALLED_DIR/$rel"

    if [[ -e $dest ]]; then
      SEEDS_SKIPPED=$((SEEDS_SKIPPED + 1))
      continue
    fi

    mkdir -p -- "$(dirname -- "$dest")"
    cp -p -- "$src" "$dest"

    # installed/envars/ holds the real API keys and generated tokens, and the
    # seeds ship world-readable (0644). Tighten the copy to owner-only; every
    # other seed keeps its mode.
    if [[ $rel == envars/* ]]; then
      chmod 600 -- "$dest"
    fi

    printf 'created   file  installed/%s\n' "$rel"
    SEEDS_COPIED=$((SEEDS_COPIED + 1))
  done < <(find "$SKEL_DIR" -type f -print0 | sort -z)
}

# 3. Seeds that no longer match the install
#
# Reported, never applied: after a `git pull` the install may be stale, and an
# install that differs may be the deliberate one. Naming them is the whole
# service -- deciding which copy wins is the operator's, and a plain diff shows
# what would change.
_reporting_drift() {
  local src rel

  while IFS= read -r -d '' src; do
    rel="${src#"$SKEL_DIR"/}"

    # Absent means this run created it; that is not drift.
    [[ -e $INSTALLED_DIR/$rel ]] || continue

    if ! cmp -s -- "$src" "$INSTALLED_DIR/$rel"; then
      printf 'differs   %s\n' "installed/$rel"
      SEEDS_DRIFTED=$((SEEDS_DRIFTED + 1))
    fi
  done < <(find "$SKEL_DIR" -type f -print0 | sort -z)
}

_printing_summary() {
  printf '\n'
  printf 'directories  %d created, %d present\n' \
    "$DIRS_CREATED"     "$(( ${#DIRS[@]} - DIRS_CREATED ))"
  printf 'seeds        %d copied, %d already present\n' \
    "$SEEDS_COPIED"     "$SEEDS_SKIPPED"

  if (( SEEDS_DRIFTED > 0 )); then
    printf 'drift        %d seed(s) differ from installed/\n' "$SEEDS_DRIFTED"
    printf '             nothing was overwritten: installed/ either carries a\n'
    printf '             deliberate edit or predates a `git pull`. Compare with\n'
    printf '             `diff -rq skel/ installed/`.\n'
  fi

  if (( SEEDS_COPIED > 0 )); then
    printf '\nSeeds were copied verbatim; replace the placeholder values before\n'
    printf 'starting the stack (installed/envars/*.env,\n'
    printf 'installed/data/agentgateway/config.yaml and\n'
    printf 'installed/data/agentgateway/agwadmins.htpasswd).\n'
  fi
}

_main() {
  _creating_directory_tree
  _copying_seeds
  _reporting_drift
  _printing_summary
}

if ! _is_sourced; then
  _main "$@"
fi
