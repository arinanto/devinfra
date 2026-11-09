#!/usr/bin/env bash
#
# scripts/pre-setup.sh -- fetch the third-party build inputs that git does not carry.
#
# scripts/setup.sh rebuilds everything this checkout can generate for itself: the
# directory tree and the *.example templates. An upstream release binary is the
# one input it cannot produce, so the forgejo-mcp bundles that
# builds/forgejomcp/Containerfile installs are fetched here instead.
#
# Why they are not committed, and not in git-lfs either: they are
# GPL-3.0-or-later object code and this repository is Apache-2.0. Committing
# them -- through LFS or not, since LFS only moves where the bytes are stored --
# would make this checkout their distributor, and GPL-3.0 §6 would then require
# the Corresponding Source to be offered alongside. Fetching them leaves that
# obligation with upstream, where it belongs. See THIRD-PARTY.md.
#
# What makes the download safe is the pinned sha256, not the TLS connection: an
# archive is unpacked only when its hash is the one recorded below, so a
# compromised or re-pointed release fails here instead of shipping a binary
# nobody chose.
#
# Re-running is the point: a bundle already in place is left alone, exactly like
# everything else under builds/. Nothing is deleted, and nothing outside the
# checkout is written except a temporary directory that is removed again.
#
# Usage:
#   ./scripts/pre-setup.sh              # the architecture this machine builds for
#   ./scripts/pre-setup.sh --all-arch    # both, for a multi-arch or cross build

set -e
set -u
set -o pipefail

# Resolve through symlinks: the script behaves the same whether it is called from
# the repo root, from a copy on $PATH, or through a symlink.
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

FORGEJO_MCP_VERSION=3.4.0
FORGEJO_MCP_NAME="forgejo-mcp"
FORGEJO_MCP_DOWNLOAD_URL="https://git.b4mad.industries/agentic-forges/forgejo-mcp/releases/download/v${FORGEJO_MCP_VERSION}"

# Where builds/forgejomcp/Containerfile looks for the bundles, one directory per
# architecture: forgejo-mcp_<version>_linux_<arch>/. Its TARGETARCH/dpkg default
# and this script's host detection have to agree on the spelling -- amd64 and
# arm64, the same words dpkg, uname and the release archives use.
BINARY_DIR="$REPO_ROOT/builds/forgejomcp/binaries"

# Architectures with a pinned release, in the order --all-arch visits them
# (associative-array key order is not stable), and the sha256 of each archive as
# published in forgejo-mcp_<version>_checksums.txt. Bumping the version above
# means re-pinning these from the checksums file of the new release and bumping
# the Containerfile's FORGEJO_MCP_VERSION ARG to match; the build fails loudly on
# a stale hash rather than quietly accepting an unknown archive.
FORGEJO_MCP_ARCHES=(amd64 arm64)
declare -A FORGEJO_MCP_SHA256=(
  [amd64]="8dca853f6d214f7ad6f40739f5cfadc739f91225c260acb207d55a22efe099b9"
  [arm64]="9083beae8eb96f4b05d2f99acd964aeb6c7632ecdfb2d4b0cbff90bfd3739ba5"
)

# Run tallies, filled in by the helpers below and reported by _printing_summary.
ARCHES_TO_FETCH=()
BUNDLES_FETCHED=0
BUNDLES_SKIPPED=0
TMP_DIR=""

# check to see if this file is being run or sourced from another script
_is_sourced() {
  # https://unix.stackexchange.com/a/215279
  [ "${#FUNCNAME[@]}" -ge 2 ] \
    && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
    && [ "${FUNCNAME[1]}" = 'source' ]
}

_usage() {
  cat <<'EOF'
usage: pre-setup.sh [--all-arch]

Fetch the forgejo-mcp release bundles that builds/forgejomcp/Containerfile
installs. Existing bundles are never replaced.

  --all-arch   fetch every pinned architecture instead of only this host's
  -h, --help   this text
EOF
}

# The architecture this machine would build for, in the vocabulary the release
# archives use. dpkg answers for any Debian-family host and already spells it
# amd64/arm64; elsewhere the uname mapping covers the same two names.
_detecting_host_arch() {
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --print-architecture
    return
  fi

  case "$(uname -m)" in
    x86_64)         printf 'amd64\n' ;;
    aarch64|arm64)  printf 'arm64\n' ;;
    *)              uname -m ;;
  esac
}

_parsing_args() {
  local arch

  while (($# > 0)); do
    case "$1" in
      --all-arch)
        ARCHES_TO_FETCH=("${FORGEJO_MCP_ARCHES[@]}")
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

  if ((${#ARCHES_TO_FETCH[@]} > 0)); then
    return
  fi

  arch="$(_detecting_host_arch)"
  if [[ -z ${FORGEJO_MCP_SHA256[$arch]:-} ]]; then
    printf 'error: no pinned forgejo-mcp release for linux/%s\n' "$arch" >&2
    printf '       pinned: %s\n' "${FORGEJO_MCP_ARCHES[*]}" >&2
    exit 1
  fi
  ARCHES_TO_FETCH=("$arch")
}

_cleaning_up() {
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  return 0
}

# Pinned-format check before anything touches the network: a bundle that already
# exists is the normal case on a second run, and it costs nothing to notice.
_fetching_bundle() {
  local arch="$1"
  local bundle="${FORGEJO_MCP_NAME}_${FORGEJO_MCP_VERSION}_linux_${arch}"
  local dest="$BINARY_DIR/$bundle"
  local archive="$bundle.tar.gz"
  local url="$FORGEJO_MCP_DOWNLOAD_URL/$archive"
  local expected="${FORGEJO_MCP_SHA256[$arch]}"
  local actual

  if [[ -x $dest/$FORGEJO_MCP_NAME ]]; then
    printf 'present   bundle %s\n' "$bundle"
    BUNDLES_SKIPPED=$((BUNDLES_SKIPPED + 1))
    return
  fi

  printf 'fetching  bundle %s\n' "$bundle"
  if ! curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP_DIR/$archive" "$url"; then
    printf 'error: could not download %s\n' "$url" >&2
    printf '       offline, blocked, or the release was moved. A browser download of\n' >&2
    printf '       the same archive unpacked by hand also satisfies this, as long as\n' >&2
    printf '       %s/%s exists, then re-run.\n' \
      "${dest#"$REPO_ROOT"/}" "$FORGEJO_MCP_NAME" >&2
    exit 1
  fi

  actual="$(sha256sum "$TMP_DIR/$archive" | cut -d ' ' -f 1)"
  if [[ $actual != "$expected" ]]; then
    printf 'error: checksum mismatch for %s\n' "$archive" >&2
    printf '       expected %s\n' "$expected" >&2
    printf '       actual   %s\n' "$actual" >&2
    printf '       nothing was unpacked. If this is a deliberate version bump,\n' >&2
    printf '       update FORGEJO_MCP_SHA256 from the release checksums file.\n' >&2
    exit 1
  fi

  # goreleaser wraps the archive in its own directory name (wrap_in_directory),
  # and that name is exactly the one the Containerfile expects, so this unpacks
  # into place without renaming anything.
  mkdir -p -- "$BINARY_DIR"
  tar -xzf "$TMP_DIR/$archive" -C "$BINARY_DIR"
  printf 'fetched   bundle %s\n' "$bundle"
  BUNDLES_FETCHED=$((BUNDLES_FETCHED + 1))
}

_printing_summary() {
  printf '\n'
  printf 'bundles      %d fetched, %d already present\n' \
    "$BUNDLES_FETCHED" "$BUNDLES_SKIPPED"

  if (( BUNDLES_FETCHED > 0 )); then
    printf '\nBundles are on this machine only; builds/forgejomcp/binaries/ stays\n'
    printf 'untracked (see THIRD-PARTY.md).\n'
  fi
}

_main() {
  local arch

  _parsing_args "$@"

  if ! command -v curl >/dev/null 2>&1; then
    printf 'error: curl not found; it is what fetches the release bundles\n' >&2
    exit 1
  fi

  TMP_DIR="$(mktemp -d)"
  trap _cleaning_up EXIT

  for arch in "${ARCHES_TO_FETCH[@]}"; do
    _fetching_bundle "$arch"
  done

  _printing_summary
}

if ! _is_sourced; then
  _main "$@"
fi
