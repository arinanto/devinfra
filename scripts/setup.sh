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
# Unit files carry @REPO_ROOT@ where the checkout's absolute path belongs, and
# the copy substitutes it: a deployment edit then need not know where the tree
# lives, and no unit has to assume %h/Containers/devinfra. The substitution is
# what makes an installed unit point at a directory that exists, so it happens
# here, before link-quadlets.sh ever sees the file.
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
# to $HOME, so the checkout may live anywhere: @REPO_ROOT@ is filled in with
# wherever it actually is.

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

# The two kinds of value in installed/envars/agentgateway.env that this script
# generates instead of leaving as a placeholder: the gateway's session key and
# every downstream route token. Kept as a sed *substitution* because the drift
# report blanks those values on both sides before comparing -- a generated value
# can never equal the seed it came from, and comparing it would name the file
# on every run of an untouched install.
SECRET_LINE_SED='s/^(AGENTGW_SESSION_KEY|DOWNSTREAM_[A-Z0-9_]+)=.*/\1=/'

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

# 0. Preconditions
#
# The gateway's session key and downstream tokens are generated while seeding,
# so openssl is not optional. Checked before anything is written, because a run
# that failed partway would leave installed/envars/agentgateway.env holding
# placeholders, and every later run would skip it as already present.
_checking_openssl() {
  if ! command -v openssl >/dev/null 2>&1; then
    printf 'setup.sh: openssl is required to generate the gateway tokens\n' >&2
    printf 'setup.sh: nothing was written\n' >&2
    exit 1
  fi
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

# Replace @REPO_ROOT@ in a seed, writing the result to stdout.
#
# The replacement is used as a sed *replacement*, so the two characters sed
# treats specially there have to be escaped: & means "the whole match" and \
# starts an escape. A checkout path containing either is unlikely and would
# otherwise corrupt the line rather than being reported.
_substituting_root() {
  local escaped="$REPO_ROOT"

  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//&/\\&}"

  sed "s|@REPO_ROOT@|$escaped|g" -- "$1"
}

# A downstream route token: 32 alphanumeric characters from the kernel CSPRNG,
# as installed/envars/agentgateway.env documents.
#
# base64 rather than hex, because hex would allow 16 symbols where 32
# characters can hold 62: same length, more entropy. 48 random bytes are 64
# base64 characters of which about 60 survive the filter, so cut always has more
# than 32 to take; it also reads to EOF, where `head -c` would close the pipe
# early and, under `set -o pipefail`, turn a SIGPIPE into a failed assignment.
# LC_ALL=C keeps the tr ranges meaning A-Z and a-z rather than whatever the
# locale says they are.
_generating_downstream_token() {
  openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-32
}

# Fill in the values that are generated rather than obtained from elsewhere:
# the gateway's session key (the guide's `openssl rand -hex 32`) and every
# DOWNSTREAM_* token. Provider keys keep their placeholder -- they come from a
# platform, not from a CSPRNG -- and so does every other line, comments included,
# which is why this rewrites only the two shapes it knows and copies the rest
# through untouched.
#
# Called on the copy, never on the seed: an installed file is skipped once it
# exists, so a rotated token or a filled-in provider key survives a re-run.
_filling_generated_values() {
  local dest="$1" line tmp="$1.tmp.$$"

  while IFS= read -r line || [[ -n $line ]]; do
    # The two shapes that are generated, matched from the start of the line so a
    # comment that happens to mention a name is left alone; everything else falls
    # through unchanged.
    case $line in
      AGENTGW_SESSION_KEY=*)
        printf 'AGENTGW_SESSION_KEY=%s\n' "$(openssl rand -hex 32)"
        ;;
      DOWNSTREAM_*=*)
        printf '%s=%s\n' "${line%%=*}" "$(_generating_downstream_token)"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done < "$dest" > "$tmp"

  # Same shape as the @REPO_ROOT@ rewrite: mode carried over from the copy, then
  # moved into place, so no half-written env file is ever loaded by a unit.
  chmod --reference="$dest" -- "$tmp"
  mv -- "$tmp" "$dest"
}

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

    # Written to a temporary file and moved into place rather than edited in
    # place, so a partially written unit cannot be left behind; chmod --reference
    # keeps the mode the copy had.
    if grep -qF -- '@REPO_ROOT@' "$dest"; then
      _substituting_root "$dest" > "$dest.tmp.$$"
      chmod --reference="$dest" -- "$dest.tmp.$$"
      mv -- "$dest.tmp.$$" "$dest"
    fi

    # The gateway's tokens are the one part of the seed that is generated rather
    # than filled in by hand, and this first copy is the only moment it happens.
    if [[ $rel == envars/agentgateway.env ]]; then
      _filling_generated_values "$dest"
    fi

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
#
# The comparison substitutes @REPO_ROOT@ first, otherwise every installed unit
# would differ from its seed by the substitution alone and the report would name
# all of them forever. The generated gateway values are blanked on both sides for
# the same reason: SECRET_LINE_SED turns `NAME=anything` into `NAME=` in the seed
# and in the install alike, so only what an operator merges by hand -- comments,
# variable names, provider keys -- is compared, and a variable added to the seed
# still shows up.
_reporting_drift() {
  local src rel

  while IFS= read -r -d '' src; do
    rel="${src#"$SKEL_DIR"/}"

    # Absent means this run created it; that is not drift.
    [[ -e $INSTALLED_DIR/$rel ]] || continue

    if ! cmp -s \
      <(_substituting_root "$src" | sed -E -- "$SECRET_LINE_SED") \
      <(sed -E -- "$SECRET_LINE_SED" "$INSTALLED_DIR/$rel"); then
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
    printf '\nSeeds were copied as-is, except that the session key and the\n'
    printf 'downstream tokens in installed/envars/agentgateway.env were generated\n'
    printf 'on the way. Still placeholders: the provider keys there, the values in\n'
    printf 'the other installed/envars/*.env files,\n'
    printf 'installed/data/agentgateway/config.yaml and\n'
    printf 'installed/data/agentgateway/agwadmins.htpasswd.\n'
  fi
}

_main() {
  _checking_openssl
  _creating_directory_tree
  _copying_seeds
  _reporting_drift
  _printing_summary
}

if ! _is_sourced; then
  _main "$@"
fi
