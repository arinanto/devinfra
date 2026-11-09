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
# The units carry no hardcoded host paths of their own: skel/quadlets/ holds
# @REPO_ROOT@ where the checkout's absolute path belongs, and scripts/setup.sh
# substitutes it while seeding. So by the time a unit is linked here its
# EnvironmentFile=, Volume= and SetWorkingDirectory= already name real
# directories, wherever this checkout lives -- there is no root to infer and no
# mismatch to warn about.
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
# REPO_ROOT is one level up from scripts/, so that the paths this script reports
# are relative to the checkout, never to scripts/.
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
  # Seeding is what makes installed/quadlets exist, and it is also where the unit
  # paths get their absolute form. Failing with the fix beats "no quadlet files
  # found".
  if [[ ! -d $QUADLET_DIR ]]; then
    printf 'error: %s does not exist\n' "${QUADLET_DIR#"$REPO_ROOT"/}" >&2
    printf '       run ./scripts/setup.sh first: it seeds installed/ from skel/\n' >&2
    exit 1
  fi

  printf 'source   %s\n' "$QUADLET_DIR"
  printf 'target   %s\n' "$TARGET_DIR"
  printf '\n'
  _installing_links
  _reporting_stale_links

  printf '\nnext: systemctl --user daemon-reload\n'
}

if ! _is_sourced; then
  _main "$@"
fi
