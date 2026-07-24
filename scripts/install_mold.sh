#!/bin/bash
set -euo pipefail

# Define variables
MOLD_VERSION="${MOLD_VERSION:-stable}"
MOLD_URL="https://github.com/rui314/mold.git"
MOLD_SRC_DIR="mold"
INITIAL_DIR="$(pwd)"

# Clone repository
git clone --branch "$MOLD_VERSION" "$MOLD_URL" "$MOLD_SRC_DIR"

# Run dependency installation (ignoring failures)
"$MOLD_SRC_DIR/install-build-deps.sh" || true

# Generate random string
generate_random_string() {
    local length=8
    tr -dc '[:lower:]' < /dev/urandom | head -c "$length" || true
}

# Create build directory
RANDOM_STRING="$(generate_random_string)"
MOLD_BUILD_DIR="$MOLD_SRC_DIR/build-$RANDOM_STRING"
mkdir -p "$MOLD_BUILD_DIR"

# Configure build
cd "$MOLD_BUILD_DIR"
cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER=c++ \
    ..

# Build and install
cmake --build . -j"$(nproc)"
cmake --build . --target install
ldconfig

# Cleanup
cd "$INITIAL_DIR"
rm -rf "$MOLD_SRC_DIR"

# Print success message
echo ""
echo "Mold version $MOLD_VERSION installation completed successfully."
echo ""
