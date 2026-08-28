#!/usr/bin/env bash
# Packages a self-contained tarball from the already-built
# postulate-hoare-release Docker image, for a GitHub Release asset --
# an alternative to the Docker image itself (see
# .github/workflows/release-hoare.yml) for anyone who'd rather not use
# Docker at all to run the compiler.
#
# "Self-contained" here means: nasm/ld's own runtime shared-library
# dependencies (found via `ldd` against the exact same Ubuntu 24.04
# build the Docker image itself uses) are bundled alongside them, and
# a wrapper `hoare` script points `LD_LIBRARY_PATH` at the bundled copies
# before running the real one -- no separate `apt install nasm binutils`
# needed on the target machine. This is a best-effort portability
# measure (works if the target's own kernel/dynamic-linker is
# compatible with Ubuntu 24.04's glibc -- true for essentially every
# actively-maintained x86-64 Linux distribution), not the same
# hermetic guarantee the Docker image itself gives; see README.md's own
# "Release" section for that trade-off spelled out for users.
#
# All staging (copying, symlink resolution, chmod +x, tar) happens
# INSIDE a container, not on the host filesystem -- running this from a
# Windows host, NTFS has no native executable bit, so a host-side
# `chmod +x` before tarring silently fails to persist and the resulting
# archive's own binaries come out non-executable (same root cause as
# the Windows-host bind-mount note in README.md). Doing it all inside
# one Linux container's own filesystem and only handing back the
# finished .tar.gz avoids that entirely, on any host.
#
# Requires `postulate-hoare-release` already built
# (docker build -f Hoare/Dockerfile.release -t postulate-hoare-release .
# from the repository root) and Docker available to run it.
set -euo pipefail

VERSION="${1:?usage: bundle_release.sh <version> <outdir>}"
OUTDIR="${2:?usage: bundle_release.sh <version> <outdir>}"
NAME="postulate-hoare-${VERSION}-linux-x86_64"

# Resolve to an absolute path (and relative to the CALLER's cwd) before
# the `cd` below moves us elsewhere -- Docker's `-v SRC:DST` treats a
# bare relative name like "dist" as a *named volume*, not a bind mount
# to ./dist, silently writing the tarball somewhere the caller (the
# release workflow's later steps, or a person running this by hand)
# will never find it.
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

cd "$(dirname "$0")/.."

MSYS_NO_PATHCONV=1 docker run --rm \
  -v "$OUTDIR:/out" \
  --entrypoint bash \
  postulate-hoare-release -c '
set -euo pipefail
NAME="'"$NAME"'"
STAGE="/tmp/$NAME"
mkdir -p "$STAGE/build" "$STAGE/bin" "$STAGE/lib" "$STAGE/docs"

# hoare.inner (below) finds this at "$SCRIPT_DIR/build/codegen",
# relative to wherever it itself ends up -- keep that exact layout.
cp /opt/hoare/build/codegen "$STAGE/build/codegen"
cp /opt/hoare/hoare "$STAGE/hoare.inner"
cp /opt/hoare/docs/postulate_v0_language_reference.md "$STAGE/docs/"

# /usr/bin/ld is a symlink chain (-> x86_64-linux-gnu-ld -> ...-ld.bfd);
# resolve to the real target so the copy is not a dangling symlink once
# it leaves this filesystem for the tarball.
NASM_REAL=$(readlink -f /usr/bin/nasm)
LD_REAL=$(readlink -f /usr/bin/ld)
cp "$NASM_REAL" "$STAGE/bin/nasm"
cp "$LD_REAL" "$STAGE/bin/ld"

# Every shared library nasm/ld actually load, from this exact image.
ldd "$NASM_REAL" "$LD_REAL" | awk "{print \$3}" | grep "^/" | sort -u | while read -r lib; do
  [ -f "$STAGE/lib/$(basename "$lib")" ] && continue
  cp "$lib" "$STAGE/lib/$(basename "$lib")"
done

cat > "$STAGE/hoare" <<WRAP
#!/usr/bin/env bash
# Self-contained wrapper: runs the bundled hoare CLI with its own
# nasm/ld found first (bin/) and their shared libraries loaded from the
# bundled copies (lib/) rather than whatever (if anything) the host has
# installed system-wide.
set -euo pipefail
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export PATH="\$DIR/bin:\$PATH"
export LD_LIBRARY_PATH="\$DIR/lib:\${LD_LIBRARY_PATH:-}"
exec "\$DIR/hoare.inner" "\$@"
WRAP

chmod +x "$STAGE/hoare" "$STAGE/hoare.inner" "$STAGE/bin/nasm" "$STAGE/bin/ld" "$STAGE/build/codegen"

tar -C /tmp -czf "/out/$NAME.tar.gz" "$NAME"
'

echo "Wrote $OUTDIR/$NAME.tar.gz"
