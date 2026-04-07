#!/bin/bash
# Builds mbedTLS + libssh as static libraries into Clibssh/libs/
# Safe to run multiple times — skips build if output already exists.
# Usage: ./scripts/build-libssh.sh [--force]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SRCROOT:-$(dirname "$SCRIPT_DIR")}"

LIBS_DIR="$PROJECT_ROOT/Clibssh/libs"
BUILD_DIR="$PROJECT_ROOT/.build/libssh-deps"

MBEDTLS_VERSION="3.6.3"
LIBSSH_VERSION="0.11.1"
MACOS_TARGET="15.0"
ARCH="arm64"

FORCE=0
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE=1
done

# Skip if already built
if [[ $FORCE -eq 0 ]] && \
   [[ -f "$LIBS_DIR/libssh.a" ]] && \
   [[ -f "$LIBS_DIR/libmbedcrypto.a" ]] && \
   [[ -f "$LIBS_DIR/libmbedtls.a" ]] && \
   [[ -f "$LIBS_DIR/libmbedx509.a" ]]; then
    echo "libssh static libs already present, skipping build."
    exit 0
fi

# Make sure Homebrew tools are in PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

for tool in cmake git; do
    if ! command -v "$tool" &>/dev/null; then
        echo "error: '$tool' not found. Install with: brew install $tool" >&2
        exit 1
    fi
done

mkdir -p "$LIBS_DIR"
mkdir -p "$BUILD_DIR"

CMAKE_PLATFORM_FLAGS=(
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_TARGET"
    -DCMAKE_BUILD_TYPE=Release
)

# ── mbedTLS ──────────────────────────────────────────────────────────────────

MBEDTLS_SRC="$BUILD_DIR/mbedtls-$MBEDTLS_VERSION"
MBEDTLS_INSTALL="$BUILD_DIR/mbedtls-install"

if [[ ! -d "$MBEDTLS_SRC" ]]; then
    echo "Cloning mbedTLS $MBEDTLS_VERSION..."
    git clone --quiet --depth 1 --branch "v$MBEDTLS_VERSION" \
        https://github.com/Mbed-TLS/mbedtls.git "$MBEDTLS_SRC"
fi

echo "Building mbedTLS..."
cmake -S "$MBEDTLS_SRC" -B "$MBEDTLS_SRC/build" \
    "${CMAKE_PLATFORM_FLAGS[@]}" \
    -DCMAKE_INSTALL_PREFIX="$MBEDTLS_INSTALL" \
    -DENABLE_TESTING=OFF \
    -DENABLE_PROGRAMS=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
    -DMBEDTLS_FATAL_WARNINGS=OFF \
    -Wno-dev -DCMAKE_MESSAGE_LOG_LEVEL=WARNING

cmake --build "$MBEDTLS_SRC/build" --parallel
cmake --install "$MBEDTLS_SRC/build" --prefix "$MBEDTLS_INSTALL"

# ── libssh ───────────────────────────────────────────────────────────────────

LIBSSH_SRC="$BUILD_DIR/libssh-$LIBSSH_VERSION"

if [[ ! -d "$LIBSSH_SRC" ]]; then
    echo "Cloning libssh $LIBSSH_VERSION..."
    git clone --quiet --depth 1 --branch "libssh-$LIBSSH_VERSION" \
        https://git.libssh.org/projects/libssh.git "$LIBSSH_SRC"
fi

echo "Building libssh..."
cmake -S "$LIBSSH_SRC" -B "$LIBSSH_SRC/build" \
    "${CMAKE_PLATFORM_FLAGS[@]}" \
    -DCMAKE_PREFIX_PATH="$MBEDTLS_INSTALL" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWITH_MBEDTLS=ON \
    -DWITH_OPENSSL=OFF \
    -DWITH_GSSAPI=OFF \
    -DWITH_EXAMPLES=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_PCAP=OFF \
    -DWITH_PKCS11_URI=OFF \
    -DUNIT_TESTING=OFF \
    -Wno-dev -DCMAKE_MESSAGE_LOG_LEVEL=WARNING

cmake --build "$LIBSSH_SRC/build" --parallel

# ── Copy static libs ─────────────────────────────────────────────────────────

echo "Copying static libraries to Clibssh/libs/..."
cp "$MBEDTLS_INSTALL/lib/libmbedcrypto.a" "$LIBS_DIR/"
cp "$MBEDTLS_INSTALL/lib/libmbedtls.a"    "$LIBS_DIR/"
cp "$MBEDTLS_INSTALL/lib/libmbedx509.a"   "$LIBS_DIR/"
cp "$LIBSSH_SRC/build/src/libssh.a"       "$LIBS_DIR/"

echo "Done. Static libs in Clibssh/libs/:"
ls -lh "$LIBS_DIR/"
