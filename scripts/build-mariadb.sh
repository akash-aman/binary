#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Build/obtain MariaDB binaries
# Usage: build-mariadb.sh <version> <platform>
# Platforms: linux-amd64, darwin-x86_64, darwin-arm64, win64
#
# Strategy:
#   - linux-amd64, win64: repackage official MariaDB tarballs
#   - darwin-*: build from source (MariaDB doesn't ship macOS binaries)
#
# Outputs to ./output/ as a self-contained MariaDB install:
#   output/bin/, output/share/, output/lib/ (where applicable)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

VERSION="${1:?Usage: build-mariadb.sh <version> <platform>}"
PLATFORM="${2:?Usage: build-mariadb.sh <version> <platform>}"

JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
BUILD_DIR="$(pwd)/build"
OUTPUT_DIR="$(pwd)/output"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo "══════════════════════════════════════════════"
echo "  MariaDB $VERSION — $PLATFORM"
echo "══════════════════════════════════════════════"

ARCHIVE_BASE="https://archive.mariadb.org/mariadb-${VERSION}"

case "$PLATFORM" in
    linux-amd64)
        # ── Repackage official Linux tarball ─────────────────
        FILE="mariadb-${VERSION}-linux-systemd-x86_64.tar.gz"
        URL="${ARCHIVE_BASE}/bintar-linux-systemd-x86_64/${FILE}"

        echo "[1/2] Downloading $FILE..."
        curl -fSL --progress-bar -o "$BUILD_DIR/$FILE" "$URL"

        echo "[2/2] Extracting..."
        cd "$BUILD_DIR"
        tar xzf "$FILE"
        SRC_DIR=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "mariadb-${VERSION}-linux*" | head -1)

        # Copy runtime essentials; skip tests, include dirs, docs
        for d in bin lib share scripts support-files; do
            [ -d "$SRC_DIR/$d" ] && cp -a "$SRC_DIR/$d" "$OUTPUT_DIR/"
        done
        ;;

    win64)
        # ── Repackage official Windows zip ───────────────────
        FILE="mariadb-${VERSION}-winx64.zip"
        URL="${ARCHIVE_BASE}/winx64-packages/${FILE}"

        echo "[1/2] Downloading $FILE..."
        curl -fSL --progress-bar -o "$BUILD_DIR/$FILE" "$URL"

        echo "[2/2] Extracting..."
        cd "$BUILD_DIR"
        unzip -q "$FILE"
        SRC_DIR=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "mariadb-${VERSION}-winx64" | head -1)

        for d in bin lib share data; do
            [ -d "$SRC_DIR/$d" ] && cp -a "$SRC_DIR/$d" "$OUTPUT_DIR/"
        done
        ;;

    darwin-x86_64|darwin-arm64)
        # ── Build from source (no official macOS binaries) ──
        FILE="mariadb-${VERSION}.tar.gz"
        URL="${ARCHIVE_BASE}/source/${FILE}"

        echo "[1/4] Installing build deps..."
        brew install cmake boost pcre2 ncurses 2>/dev/null || true

        echo "[2/4] Downloading source..."
        curl -fSL --progress-bar -o "$BUILD_DIR/$FILE" "$URL"

        echo "[3/4] Extracting..."
        cd "$BUILD_DIR"
        tar xzf "$FILE"
        SRC_DIR="$BUILD_DIR/mariadb-${VERSION}"
        cd "$SRC_DIR"

        echo "[4/4] Compiling (this takes a while)..."
        mkdir -p build && cd build

        # WITH_SSL=bundled: use MariaDB's bundled WolfSSL, avoiding brew openssl
        #   dependency for portability.
        # WITH_PCRE=bundled: use bundled PCRE2.
        # Disable optional components to speed up build and keep output small.
        cmake .. \
            -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
            -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR" \
            -DINSTALL_LAYOUT=STANDALONE \
            -DWITH_SSL=bundled \
            -DWITH_PCRE=bundled \
            -DWITH_ZLIB=bundled \
            -DWITH_UNIT_TESTS=OFF \
            -DWITHOUT_TOKUDB=1 \
            -DWITHOUT_MROONGA=1 \
            -DWITHOUT_ROCKSDB=1 \
            -DWITHOUT_CONNECT=1 \
            -DWITHOUT_SPHINX=1 \
            -DWITHOUT_SPIDER=1 \
            -DWITHOUT_OQGRAPH=1 \
            -DPLUGIN_AUTH_PAM=NO \
            -DPLUGIN_HANDLERSOCKET=NO

        make -j"$JOBS"
        make install

        # Strip debug info & drop unneeded dirs to reduce size
        rm -rf "$OUTPUT_DIR/mysql-test" "$OUTPUT_DIR/sql-bench" \
               "$OUTPUT_DIR/man" "$OUTPUT_DIR/include" 2>/dev/null || true
        find "$OUTPUT_DIR/bin" -type f -exec strip {} + 2>/dev/null || true
        ;;

    *)
        echo "✗ Unknown platform: $PLATFORM"
        exit 1
        ;;
esac

chmod +x "$OUTPUT_DIR/bin/"* 2>/dev/null || true

echo ""
echo "══════════════════════════════════════════════"
echo "  ✓ MariaDB $VERSION for $PLATFORM"
echo "══════════════════════════════════════════════"
echo "Output directory:"
du -sh "$OUTPUT_DIR" 2>/dev/null || ls -lh "$OUTPUT_DIR"
echo ""
echo "Binaries:"
ls -lh "$OUTPUT_DIR/bin/" 2>/dev/null | head -15 || true
