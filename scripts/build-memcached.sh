#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Build Memcached from source (with static libevent)
# Usage: build-memcached.sh <version> <platform>
# Platforms: linux-amd64, darwin-arm64
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

./configure \
    --prefix="$LIBEVENT_PREFIX" \
    --disable-shared \
    --enable-static \
    --disable-openssl \
    --disable-debug-mode \
    --quiet

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

# Strip -Werror and -pedantic from Makefile.in BEFORE configure.
# Older memcached (1.4.x, 1.5.x) has code that triggers warnings treated as
# errors on modern compilers (deprecated sigignore, missing prototypes,
# format-truncation). memcached's Makefile.am hardcodes -Werror in AM_CFLAGS,
# baked into Makefile.in. We patch Makefile.in (not Makefile.am) so make
# doesn't try to regenerate it via automake (which may not be installed).
strip_werror() {
    find . -name Makefile.in -exec sed -i.bak \
        -e 's/-Werror//g' -e 's/-pedantic//g' {} +
    # Bump mtime so make doesn't try to regenerate from Makefile.am
    find . -name Makefile.in -exec touch {} +
}

# If from GitHub source (no configure), run autogen first
if [ ! -f "configure" ] && [ -f "autogen.sh" ]; then
    echo "  Running autogen..."
    ./autogen.sh
fi

echo "  Stripping -Werror from Makefile.in..."
strip_werror

# ── Step 4: Compile ──────────────────────────────────────────
echo ""
echo "[4/4] Compiling Memcached $VERSION..."

case "$PLATFORM" in
    linux-amd64)
        # Static build on Linux
        ./configure \
            --with-libevent="$LIBEVENT_PREFIX" \
            --disable-coverage \
            --disable-docs \
            --quiet \
            LDFLAGS="-static"
        ;;
    darwin-arm64)
        # macOS: static libevent, dynamic system libs
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

# Final safety net: also strip from generated Makefile in case any path
# re-introduced it (e.g., subdirs not covered above).
find . -name Makefile -exec sed -i.bak -e 's/-Werror//g' -e 's/-pedantic//g' {} +
# Bump mtime so make doesn't try to regenerate from Makefile.in
find . -name Makefile -exec touch {} +

make -j"$JOBS"

# ── Collect binary ───────────────────────────────────────────
cp memcached "$OUTPUT_DIR/"

chmod +x "$OUTPUT_DIR"/* 2>/dev/null || true

echo ""
echo "══════════════════════════════════════════════"
echo "  ✓ Memcached $VERSION for $PLATFORM"
echo "══════════════════════════════════════════════"
ls -lh "$OUTPUT_DIR/"
