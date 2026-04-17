#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Build Memcached from source (with static libevent)
# Usage: build-memcached.sh <version> <platform>
# Platforms: linux-amd64, darwin-amd64, darwin-arm64, windows-amd64
#
# Builds libevent as a static library first, then links memcached
# against it. Based on gowp's setup-memcached-macos.sh pattern.
#
# Outputs binary to ./output/
# ──────────────────────────────────────────────────────────────
set -euo pipefail

VERSION="${1:?Usage: build-memcached.sh <version> <platform>}"
PLATFORM="${2:?Usage: build-memcached.sh <version> <platform>}"

JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
BUILD_DIR="$(pwd)/build"
OUTPUT_DIR="$(pwd)/output"
LIBEVENT_PREFIX="$BUILD_DIR/libevent-prefix"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo "══════════════════════════════════════════════"
echo "  Memcached $VERSION — $PLATFORM"
echo "  Parallel jobs: $JOBS"
echo "══════════════════════════════════════════════"

# ── Step 1: Resolve libevent version ─────────────────────────
echo ""
echo "[1/4] Resolving libevent version..."

LIBEVENT_VERSION=$(curl -fsSL "https://api.github.com/repos/libevent/libevent/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | sed 's/.*"release-//;s/".*//') || true

if [ -z "$LIBEVENT_VERSION" ]; then
    LIBEVENT_VERSION="2.1.12-stable"
    echo "  ⚠ API unavailable, using fallback: $LIBEVENT_VERSION"
else
    echo "  libevent: $LIBEVENT_VERSION"
fi

# ── Step 2: Build libevent (static) ─────────────────────────
echo ""
echo "[2/4] Building libevent $LIBEVENT_VERSION (static)..."

LIBEVENT_TAR="$BUILD_DIR/libevent-$LIBEVENT_VERSION.tar.gz"
curl -fSL --progress-bar -o "$LIBEVENT_TAR" \
    "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz"

cd "$BUILD_DIR"
tar xzf "$LIBEVENT_TAR"
cd "libevent-$LIBEVENT_VERSION"

# Older libevent samples/tests have pointer-type issues with newer GCC (14+)
# on Windows/MinGW. These are hard errors in GCC 14, not just warnings.
# Fully disable since we only need the static library, not samples/tests.
LIBEVENT_CFLAGS=""
if [ "$PLATFORM" = "windows-amd64" ]; then
    LIBEVENT_CFLAGS="-Wno-incompatible-pointer-types -Wno-int-conversion"
fi

./configure \
    --prefix="$LIBEVENT_PREFIX" \
    --disable-shared \
    --enable-static \
    --disable-openssl \
    --disable-debug-mode \
    --quiet \
    ${LIBEVENT_CFLAGS:+CFLAGS="$LIBEVENT_CFLAGS"}

make -j"$JOBS"
make install
echo "  ✓ libevent built"

# ── Step 3: Download memcached ───────────────────────────────
echo ""
echo "[3/4] Downloading Memcached $VERSION..."

MEMCACHED_TAR="$BUILD_DIR/memcached-$VERSION.tar.gz"
CLEAN_VER="${VERSION#v}"

# Try memcached.org first (stable releases), fallback to GitHub
curl -fSL --progress-bar -o "$MEMCACHED_TAR" \
    "https://memcached.org/files/memcached-${CLEAN_VER}.tar.gz" 2>/dev/null \
    || curl -fSL --progress-bar -o "$MEMCACHED_TAR" \
    "https://github.com/memcached/memcached/archive/refs/tags/${VERSION}.tar.gz"

cd "$BUILD_DIR"
tar xzf "$MEMCACHED_TAR"

# Find extracted directory (handles different naming conventions)
MEMCACHED_SRC=$(find "$BUILD_DIR" -maxdepth 1 -name "memcached-*" -type d | grep -v libevent | head -1)
if [ -z "$MEMCACHED_SRC" ]; then
    echo "  ✗ Failed to find memcached source directory"
    exit 1
fi

cd "$MEMCACHED_SRC"

# If from GitHub source (no configure), run autogen
if [ ! -f "configure" ] && [ -f "autogen.sh" ]; then
    echo "  Running autogen..."
    ./autogen.sh
fi

# ── Step 4: Compile ──────────────────────────────────────────
echo ""
echo "[4/4] Compiling Memcached $VERSION..."

case "$PLATFORM" in
    linux-amd64)
        # Fully static build on Linux
        ./configure \
            --with-libevent="$LIBEVENT_PREFIX" \
            --disable-coverage \
            --disable-docs \
            --quiet \
            LDFLAGS="-static"
        ;;
    darwin-amd64|darwin-arm64)
        # macOS: static libevent, dynamic system libs
        ./configure \
            --with-libevent="$LIBEVENT_PREFIX" \
            --disable-coverage \
            --disable-docs \
            --quiet
        ;;
    windows-amd64)
        # Windows/MSYS2: best-effort build
        ./configure \
            --with-libevent="$LIBEVENT_PREFIX" \
            --disable-coverage \
            --disable-docs \
            --quiet
        ;;
    *)
        echo "✗ Unknown platform: $PLATFORM"
        exit 1
        ;;
esac

make -j"$JOBS"

# ── Collect binary ───────────────────────────────────────────
if [ "$PLATFORM" = "windows-amd64" ]; then
    if [ -f "memcached.exe" ]; then
        cp memcached.exe "$OUTPUT_DIR/"
    elif [ -f "memcached" ]; then
        cp memcached "$OUTPUT_DIR/memcached.exe"
    fi
else
    cp memcached "$OUTPUT_DIR/"
fi

chmod +x "$OUTPUT_DIR"/* 2>/dev/null || true

echo ""
echo "══════════════════════════════════════════════"
echo "  ✓ Memcached $VERSION for $PLATFORM"
echo "══════════════════════════════════════════════"
ls -lh "$OUTPUT_DIR/"
