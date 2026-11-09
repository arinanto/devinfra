# Third-party software

An acknowledgement of the third-party code this repository builds into an image
or keeps in the tree, and the licence that code carries. It is not a licence
audit: the authoritative text for each component ships with the component, and
is cited below rather than restated.

Nothing here changes the licence of this repository's own files, which is
Apache-2.0 — see [`LICENSE`](LICENSE). A program under another licence, copied
into an image this repository builds, stays under its own licence. Same medium
is not a combined work: nothing links against it, and the processes reach each
other over a socket.

## forgejo-mcp

| | |
|---|---|
| Version | 3.4.0 |
| Licence | GPL-3.0-or-later |
| Copyright | © the forgejo-mcp authors |
| Upstream | <https://git.b4mad.industries/agentic-forges/forgejo-mcp> |
| Source for this version | tag `v3.4.0`, commit `888d80c` |
| Licence text | `LICENSE` in the release bundle, installed as `/usr/share/licenses/forgejo-mcp/LICENSE` |
| Built into | the image from `builds/forgejomcp/Containerfile`, at `/usr/local/bin/forgejo-mcp` |
| Modified | no; the release binary is copied unmodified |

Upstream publishes it as a prebuilt bundle per architecture —
`forgejo-mcp_3.4.0_linux_<arch>/` containing the binary, a `README.md` and the
`LICENSE` — alongside `checksums.txt` and, when the release was signed, a
cosign signature. `scripts/pre-setup.sh` unpacks the bundle into
`builds/forgejomcp/binaries/`, which is where that Containerfile expects to find
it, and only after the archive matches the sha256 that release's checksums file
lists, recorded in the script. The directory name carries the version without
the `v` the tag has. `forgejo-mcp`'s own README, which travels in the bundle,
documents how to verify the checksums and signature.

The binary is fetched per checkout — not by the build, and not on every build —
so this repository distributes no GPL object code and no image built here is
published: the build happens on the machine that runs the stack.
`builds/forgejomcp/binaries/` is gitignored for exactly that reason. Committing
it would make this repository the distributor, through git-lfs as much as
through git, since LFS only moves where the bytes are stored; GPL-3.0 §6 would
then require the Corresponding Source for that version to be offered with it,
not merely pointed at from here.

If an image built by this repository is ever pushed to a registry, the same
applies to the image: convey the Corresponding Source (the `v3.4.0` tag above)
with it, or a written offer to supply it. Upstream publishes a signed image of
its own, `linux/amd64` only, for anyone who would rather pull than convey.

## Not itemised here

The rest of the stack arrives as unmodified upstream container images
(`postgres`, `valkey`, `agentgateway`, Playwright MCP) pulled by the Quadlets, or
as Debian packages installed into an image this repository builds (`postgisvec`).
Their licences and notices stay with them — in the image's
`/usr/share/doc/` for Debian packages, in the publisher's metadata for the
pulled images — and are deliberately not copied up into this file, which would
only go stale.
