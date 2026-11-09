#!/usr/bin/env bash
#
# scripts/link-quadlets.sh -- link installed/quadlets/ into the rootless Quadlet
# search path.
#
# Quadlet only reads units from fixed directories, so the units this machine runs
# have to appear under ~/.config/containers/systemd. The source is installed/
# rather than skel/: systemd must load the copy a deployment has tuned, not the
# seed. Symlinking rather than copying means an edit to that copy takes effect on
# the next `systemctl --user daemon-reload` with no third copy to keep in sync.
#
# The quadlets hardcode their host paths as %h/Containers/devinfra/... because
# systemd expands %h to the invoking user's home. Those paths are baked into the
# generated podman commands, so a checkout living anywhere else resolves every
# volume against a directory that does not exist. This script therefore works
# out which root the quadlets expect (see _extracting_expected_root), compares it
# with where this checkout actually is, and says so rather than failing silently.
# It links anyway: an install that starts with a clear warning is more useful
# than one that refuses to run.
#
# Nothing here is destructive. Existing links are replaced, dangling links that
# point into this checkout are reported, and files this script did not create are
# never touched.

set -e
set -u
set -o pipefail

# Resolve through symlinks, so the script behaves the same whether it is called
# as ./scripts/link-quadlets.sh, ../../devinfra/scripts/link-quadlets.sh, or
# through a symlink on $PATH. $0 alone would carry the caller's relative path.
# REPO_ROOT is one level up from scripts/: the quadlets, and the %h paths they
# expand to, are relative to the checkout, never to scripts/.
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
QUADLET_DIR="$REPO_ROOT/installed/quadlets"

# Rootless Quadlet search path: $XDG_CONFIG_HOME/containers/systemd, which
# defaults to ~/.config/containers/systemd. Respect XDG_CONFIG_HOME when set.
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
TARGET_DIR="$CONFIG_HOME/containers/systemd"

# Extensions Quadlet actually reads. Anything else in installed/quadlets/ stays
# out of the search path, where an unknown suffix could otherwise confuse a
# reader.
QUADLET_EXTENSIONS=(container build network)

# check to see if this file is being run or sourced from another script
_is_sourced() {
  # https://unix.stackexchange.com/a/215279
  [ "${#FUNCNAME[@]}" -ge 2 ] \
    && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
    && [ "${FUNCNAME[1]}" = 'source' ]
}

# Work out the root the quadlets expect, as %h/<words...>.
#
# Rather than assuming the layout, each hardcoded path is matched against this
# checkout: the longest trailing part of it that exists under $REPO_ROOT is the
# sub-tree the path points into, and everything before that sub-tree is the
# expected root. For %h/Containers/devinfra/installed/data/valkey with a
# checkout at ~/workspaces/devinfra this yields %h/Containers/devinfra, whatever
# the depth.
_extracting_expected_root() {
  local -a matches
  local match rel suffix prefix
  local -A seen=()

  # Paths are followed by ':' in Volume=, ',' in overlay options, or whitespace,
  # so none of those can be part of a path component.
  mapfile -t matches < <(
    grep -ohE '%h/[^[:space:]:,]+' "$QUADLET_DIR"/* 2>/dev/null | sort -u
  )

  (( ${#matches[@]} > 0 )) || return 0

  for match in "${matches[@]}"; do
    rel="${match#%h/}"

    suffix="$rel"
    while [[ -n $suffix && ! -e "$REPO_ROOT/$suffix" ]]; do
      [[ $suffix == */* ]] || { suffix=""; break; }
      suffix="${suffix#*/}"
    done

    # No part of this path exists here, so it says nothing about the root.
    [[ -n $suffix ]] || continue

    prefix="${rel%"$suffix"}"
    prefix="${prefix%/}"
    [[ -n $prefix ]] || continue

    seen["%h/$prefix"]=1
  done

  (( ${#seen[@]} > 0 )) || return 0

  # Sorted for a deterministic answer if the files ever disagree.
  printf '%s\n' "${!seen[@]}" | sort | head -n 1
}

_reporter_root_mismatch() {
  local expected="$1"
  local expected_abs="${expected/#%h/$HOME}"
  local resolved=""

  if [[ -e $expected_abs ]]; then
    resolved="$(realpath -e "$expected_abs")"
  fi

  # A symlink at the expected path pointing back here is the documented setup
  # (see README), so compare resolved targets rather than the literal paths.
  if [[ $resolved == "$REPO_ROOT" ]]; then
    printf 'paths    %s resolves to this checkout\n' "$expected_abs"
    return 0
  fi

  printf '\n' >&2
  printf 'warning: the quadlets hardcode %s\n' "$expected" >&2
  printf '         this checkout is %s\n' "$REPO_ROOT" >&2
  if [[ -z $resolved ]]; then
    printf '         %s does not exist.\n' "$expected_abs" >&2
    printf '         expected layout: %s -> %s\n' "$expected_abs" "$REPO_ROOT" >&2
    printf '         mkdir -p %s && ln -s %s %s\n' \
      "$(dirname "$expected_abs")" "$REPO_ROOT" "$expected_abs" >&2
  else
    printf '         %s resolves to %s\n' "$expected_abs" "$resolved" >&2
  fi
  printf '         Volumes will point outside this checkout until they agree.\n' >&2
}

_installing_links() {
  local -a files=()
  local ext file name source

  for ext in "${QUADLET_EXTENSIONS[@]}"; do
    for file in "$QUADLET_DIR"/*."$ext"; do
      [[ -e $file ]] || continue
      files+=("$file")
    done
  done

  if (( ${#files[@]} == 0 )); then
    printf 'error: no quadlet files found in %s\n' "$QUADLET_DIR" >&2
    exit 1
  fi

  mkdir -p "$TARGET_DIR"

  for file in "${files[@]}"; do
    name="$(basename "$file")"
    # Link the physical path so the link resolves no matter which directory this
    # was invoked from. -n stops ln from following an existing link that points
    # at a directory and nesting the new link inside it.
    source="$(realpath -e "$file")"
    ln -snf -- "$source" "$TARGET_DIR/$name"
    printf 'linked   %s -> %s\n' "$name" "$source"
  done
}

# A quadlet renamed or deleted here leaves a dangling link behind. Report those,
# but only ones pointing into this checkout: a link planted by something else is
# none of this script's business, and deleting anything is not best-effort.
_reporting_stale_links() {
  local link target
  local count=0

  for link in "$TARGET_DIR"/*; do
    [[ -L $link && ! -e $link ]] || continue
    target="$(readlink -- "$link")"
    case "$target" in
      "$REPO_ROOT"/*)
        printf 'stale    %s -> %s\n' "$(basename "$link")" "$target"
        count=$((count + 1))
        ;;
    esac
  done

  if (( count > 0 )); then
    printf 'note: %d dangling link(s) left in place; remove them by hand if unwanted\n' \
      "$count"
  fi
}

_main() {
  local expected

  # Seeding is what makes installed/quadlets exist, and every unit path in it
  # points there too. Failing with the fix beats "no quadlet files found".
  if [[ ! -d $QUADLET_DIR ]]; then
    printf 'error: %s does not exist\n' "${QUADLET_DIR#"$REPO_ROOT"/}" >&2
    printf '       run ./scripts/setup.sh first: it seeds installed/ from skel/\n' >&2
    exit 1
  fi

  expected="$(_extracting_expected_root)"

  printf 'source   %s\n' "$QUADLET_DIR"
  printf 'target   %s\n' "$TARGET_DIR"

  if [[ -n $expected ]]; then
    _reporter_root_mismatch "$expected"
  else
    printf 'paths    could not infer the expected root; not checking\n'
  fi

  printf '\n'
  _installing_links
  _reporting_stale_links

  printf '\nnext: systemctl --user daemon-reload\n'
}

if ! _is_sourced; then
  _main "$@"
fi
