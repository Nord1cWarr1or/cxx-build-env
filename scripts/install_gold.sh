#!/bin/bash
set -euo pipefail

# Side-install of ld.gold into the devtoolset prefix.
#
# Gold was removed from binutils in 2.44; the last release that ships it is
# 2.43. Projects pin author gold flag sets (-fuse-ld=gold with -Wl,--icf=safe,
# -Wl,--warn-drop-version, -Wl,--detect-odr-violations, ...) that need a
# modern gold, while the base distro only carries an ancient system one
# (EL7 ships 2.27, which predates --warn-drop-version).
#
# This script builds gold from the last gold-capable binutils release and
# installs ONLY its ld.gold binary next to the newer ld.bfd, so
# -fuse-ld=gold resolves inside the devtoolset prefix instead of falling
# back to the system linker. The main binutils install (scripts/
# install_binutils.sh) is untouched.

# Last binutils release that ships gold.
GOLD_VERSION="${GOLD_VERSION:-2.43}"
GOLD_URL="https://ftpmirror.gnu.org/gnu/binutils/binutils-$GOLD_VERSION.tar.gz"
GOLD_TAR_FILE="gold.tar.gz"
GOLD_SRC_DIR="binutils-$GOLD_VERSION"
GOLD_INSTALL_PREFIX="${GOLD_INSTALL_PREFIX:-${BINUTILS_PREFIX:-/usr}}"
INITIAL_DIR="$(pwd)"

# Download and extract source tarball.
if [ ! -f "$GOLD_TAR_FILE" ]; then
    wget -O "$GOLD_TAR_FILE" "$GOLD_URL"
fi
tar -xzf "$GOLD_TAR_FILE"

# Build directory.
RANDOM_STRING="$(tr -dc '[:lower:]' < /dev/urandom | head -c "$((8))" || true)"
GOLD_BUILD_DIR="$GOLD_SRC_DIR/build-$RANDOM_STRING"
mkdir -p "$GOLD_BUILD_DIR"
cd "$GOLD_BUILD_DIR"

# Configure a gold-only build: everything else is disabled so the tree
# produces exactly one binary. MAKEINFO=true: no texinfo in build containers.
../configure \
    --prefix="$GOLD_INSTALL_PREFIX" \
    --enable-gold \
    --disable-ld \
    --disable-binutils \
    --disable-gas \
    --disable-gprof \
    --disable-gprofng \
    --disable-gdb \
    --disable-sim \
    --disable-readline \
    --disable-libdecnumber \
    --disable-nls \
    --disable-werror

make -j"$(nproc)" MAKEINFO=true

# Install only the gold binary; `make install` would also install an `ld`
# that shadows the newer ld.bfd.
install -d "$GOLD_INSTALL_PREFIX/bin"
install -m 755 gold/ld-new "$GOLD_INSTALL_PREFIX/bin/ld.gold"

# Cleanup.
cd "$INITIAL_DIR"
rm -rf "$GOLD_SRC_DIR" "$GOLD_TAR_FILE"

# Print success message.
echo ""
echo "GNU gold (from binutils $GOLD_VERSION) installed as $GOLD_INSTALL_PREFIX/bin/ld.gold."
echo ""
