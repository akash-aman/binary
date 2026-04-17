#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Build Redis from source
# Usage: build-redis.sh <version> <platform>
# Platforms: linux-amd64, darwin-arm64
#
# Outputs binaries to ./output/
# ──────────────────────────────────────────────────────────────
set -euo pipefail

VERSION="${1:?Usage: build-redis.sh <version> <platform>}"
PLATFORM="${2:?Usage: build-redis.sh <version> <platform>}"

JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
BUILD_DIR="$(pwd)/build"
OUTPUT_DIR="$(pwd)/output"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo "══════════════════════════════════════════"
echo "  Redis $VERSION — $PLATFORM"
echo "  Parallel jobs: $JOBS"
echo "══════════════════════════════════════════"

# ── Download ──────────────────────────────────────────────────
echo ""
echo "[1/3] Downloading Redis $VERSION..."
TARBALL="$BUILD_DIR/redis-$VERSION.tar.gz"
curl -fSL --progress-bar -o "$TARBALL" \
    "https://github.com/redis/redis/archive/refs/tags/$VERSION.tar.gz"

cd "$BUILD_DIR"
tar xzf "$TARBALL"
cd "redis-$VERSION"

# ── Compile ───────────────────────────────────────────────────
echo ""
echo "[2/3] Compiling..."

case "$PLATFORM" in
    linux-amd64)
        # Fully static build on Linux
        make -j"$JOBS" \
            MALLOC=libc \
            LDFLAGS="-static"
        ;;
    darwin-arm64)
        # macOS: dynamic system libs (Apple doesn't allow fully static)
        make -j"$JOBS" \
            MALLOC=libc
        ;;
    *)
        echo "✗ Unknown platform: $PLATFORM"
        exit 1
        ;;
esac

# ── Collect binaries ─────────────────────────────────────────
echo ""
echo "[3/3] Collecting binaries..."

BINARIES="redis-server redis-cli redis-benchmark"

for bin in $BINARIES; do
    if [ -f "src/$bin" ]; then
        cp "src/$bin" "$OUTPUT_DIR/$bin"
        SIZE=$(ls -lh "src/$bin" | awk '{print $5}')
        echo "  ✓ $bin ($SIZE)"
    else
        echo "  ⚠ $bin not found"
    fi
done

chmod +x "$OUTPUT_DIR"/* 2>/dev/null || true

echo ""
echo "══════════════════════════════════════════"
echo "  ✓ Redis $VERSION for $PLATFORM"
echo "══════════════════════════════════════════"
ls -lh "$OUTPUT_DIR/"
