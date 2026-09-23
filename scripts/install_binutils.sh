#!/bin/bash
set -euo pipefail

# Define variables
BINUTILS_URL="https://ftpmirror.gnu.org/gnu/binutils/binutils-$BINUTILS_VERSION.tar.gz"
BINUTILS_PREFIX="${BINUTILS_PREFIX:-/usr}"
BINUTILS_PROGRAM_PREFIX="${BINUTILS_PROGRAM_PREFIX:-}"
BINUTILS_TAR_FILE="binutils.tar.gz"
BINUTILS_SRC_DIR="binutils-$BINUTILS_VERSION"
INITIAL_DIR="$(pwd)"

# Download and extract source tarball
wget -O "$BINUTILS_TAR_FILE" "$BINUTILS_URL"
tar -xzf "$BINUTILS_TAR_FILE"

# Generate random string
generate_random_string() {
    local length=8
    tr -dc '[:lower:]' < /dev/urandom | head -c "$length" || true
}

# Create build directory
RANDOM_STRING="$(generate_random_string)"
BINUTILS_BUILD_DIR="$BINUTILS_SRC_DIR/build-$RANDOM_STRING"
mkdir -p "$BINUTILS_BUILD_DIR"

# Configure build.
# gprofng (added in binutils 2.39) requires bison >= 3.0.4, which build
# containers do not ship; it is irrelevant for a toolchain image.
# NOTE: gold was removed from binutils in 2.44 — ld.gold is installed
# separately by scripts/install_gold.sh.
cd "$BINUTILS_BUILD_DIR"
../configure \
    --prefix="$BINUTILS_PREFIX" \
    --program-prefix="$BINUTILS_PROGRAM_PREFIX" \
    --enable-ld=yes \
    --enable-multilib \
    --disable-gprofng \
    --disable-nls \
    --disable-werror

# Build and install.
# MAKEINFO=true: build containers ship no texinfo; when the tarball's
# prebuilt docs look stale, make would otherwise try to regenerate
# bfd.info with a missing makeinfo and die with exit 127.
make -j"$(nproc)" MAKEINFO=true
make install MAKEINFO=true
ldconfig

# Cleanup
cd "$INITIAL_DIR"
rm -rf "$BINUTILS_SRC_DIR" "$BINUTILS_TAR_FILE"

# Print success message
echo ""
echo "GNU Binary Utilities version $BINUTILS_VERSION installation completed successfully."
echo ""
