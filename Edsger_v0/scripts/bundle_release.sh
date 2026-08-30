#!/usr/bin/env bash
# Packages a self-contained tarball from the already-built
# postulate-edsger-release Docker image, for a GitHub Release asset --
# an alternative to the Docker image itself (see
# .github/workflows/release-edsger.yml) for anyone who'd rather not use
# Docker at all to run the compiler. Mirrors Hoare/scripts/bundle_
# release.sh exactly (llc/ld instead of nasm/ld) -- see that script's
# own header comment for the full rationale (why bundle at all, why
# entirely inside a container, the portability trade-off vs. the
# Docker image itself).
#
# Requires `postulate-edsger-release` already built
# (docker build -f Edsger_v0/Dockerfile.release -t postulate-edsger-release Edsger_v0)
# and Docker available to run it.
set -euo pipefail

VERSION="${1:?usage: bundle_release.sh <version> <outdir>}"
OUTDIR="${2:?usage: bundle_release.sh <version> <outdir>}"
NAME="postulate-edsger-${VERSION}-linux-x86_64"

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
  postulate-edsger-release -c '
set -euo pipefail
NAME="'"$NAME"'"
STAGE="/tmp/$NAME"
mkdir -p "$STAGE/build" "$STAGE/bin" "$STAGE/lib" "$STAGE/docs"

# edsger.inner (below) finds this at "$SCRIPT_DIR/build/codegen",
# relative to wherever it itself ends up -- keep that exact layout.
cp /opt/edsger/build/codegen "$STAGE/build/codegen"
cp /opt/edsger/edsger "$STAGE/edsger.inner"
cp /opt/edsger/docs/postulate_v1_0_language_reference.md "$STAGE/docs/"

# /usr/bin/ld is a symlink chain (-> x86_64-linux-gnu-ld -> ...-ld.bfd);
# llc is typically versioned (llc-18) with a plain "llc" symlink to it.
# Resolve both to their real targets so neither copy is a dangling
# symlink once it leaves this filesystem for the tarball.
LLC_REAL=$(readlink -f "$(command -v llc)")
LD_REAL=$(readlink -f /usr/bin/ld)
cp "$LLC_REAL" "$STAGE/bin/llc"
cp "$LD_REAL" "$STAGE/bin/ld"

# Every shared library llc/ld actually load, from this exact image.
ldd "$LLC_REAL" "$LD_REAL" | awk "{print \$3}" | grep "^/" | sort -u | while read -r lib; do
  [ -f "$STAGE/lib/$(basename "$lib")" ] && continue
  cp "$lib" "$STAGE/lib/$(basename "$lib")"
done

cat > "$STAGE/edsger" <<WRAP
#!/usr/bin/env bash
# Self-contained wrapper: runs the bundled edsger CLI with its own
# llc/ld found first (bin/) and their shared libraries loaded from the
# bundled copies (lib/) rather than whatever (if anything) the host has
# installed system-wide.
set -euo pipefail
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export PATH="\$DIR/bin:\$PATH"
export LD_LIBRARY_PATH="\$DIR/lib:\${LD_LIBRARY_PATH:-}"
exec "\$DIR/edsger.inner" "\$@"
WRAP

chmod +x "$STAGE/edsger" "$STAGE/edsger.inner" "$STAGE/bin/llc" "$STAGE/bin/ld" "$STAGE/build/codegen"

tar -C /tmp -czf "/out/$NAME.tar.gz" "$NAME"
'

echo "Wrote $OUTDIR/$NAME.tar.gz"
