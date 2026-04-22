#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Build a bundle of PHP extensions for one PHP minor version.
# Usage: build-php-extensions.sh <php-minor> <platform>
#   <php-minor>: 8.1 | 8.2 | 8.3 | 8.4
#   <platform>:  linux-amd64 | darwin-arm64
#
# PHP extensions are ABI-compatible per PHP minor version (the
# ZEND_MODULE_API_NO only changes between minors). So a .so built
# against PHP 8.3.x works with any 8.3.y on the same platform.
#
# Extensions built:
#   Core  : opcache (copied from PHP distribution)
#   PECL  : igbinary, apcu, yaml, msgpack, redis, memcached,
#           imagick, xdebug
#
# Outputs .so files to ./output/extensions/ plus a README.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

VERSION="${1:?Usage: build-php-extensions.sh <php-minor> <platform>}"
PLATFORM="${2:?Usage: build-php-extensions.sh <php-minor> <platform>}"

JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
BUILD_DIR="$(pwd)/build"
OUTPUT_DIR="$(pwd)/output"
EXT_DIR="$OUTPUT_DIR/extensions"
mkdir -p "$BUILD_DIR" "$EXT_DIR"

# ── Pinned extension versions ────────────────────────────────
# Bump here when you want newer extension releases.
IGBINARY_VER="3.2.16"
APCU_VER="5.1.24"
YAML_VER="2.2.4"
MSGPACK_VER="2.2.0RC2"
REDIS_VER="6.2.0"
MEMCACHED_VER="3.3.0"

# imagick: 3.7.0 misbuilds on PHP 8.4+; the 3.8.0 line adds 8.4/8.5 support.
case "$VERSION" in
    8.1|8.2|8.3) IMAGICK_VER="3.7.0" ;;
    *)           IMAGICK_VER="3.8.0" ;;
esac

XDEBUG_VER="3.4.5"

echo "══════════════════════════════════════════════"
echo "  PHP $VERSION extensions — $PLATFORM"
echo "  Parallel jobs: $JOBS"
echo "══════════════════════════════════════════════"

# ── Install PHP toolchain + native deps ──────────────────────
case "$PLATFORM" in
    linux-amd64)
        echo ""
        echo "[setup] Installing PHP $VERSION dev toolchain + native deps..."
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update -qq
        sudo apt-get install -y -qq software-properties-common
        sudo add-apt-repository -y ppa:ondrej/php
        sudo apt-get update -qq
        sudo apt-get install -y -qq \
            "php${VERSION}-cli" "php${VERSION}-dev" "php${VERSION}-opcache" \
            build-essential autoconf pkg-config re2c bison \
            libmagickwand-dev libmemcached-dev libyaml-dev \
            libssl-dev zlib1g-dev
        PHP_CONFIG="/usr/bin/php-config${VERSION}"
        PHPIZE="/usr/bin/phpize${VERSION}"
        SUDO="sudo"
        ;;
    darwin-arm64)
        echo ""
        echo "[setup] Installing PHP $VERSION dev toolchain + native deps..."
        brew update >/dev/null
        # shellcheck disable=SC2086
        brew install \
            "php@${VERSION}" \
            autoconf pkg-config re2c bison \
            imagemagick libmemcached libyaml openssl@3 zlib 2>/dev/null || true
        PHP_PREFIX="$(brew --prefix "php@${VERSION}")"
        export PATH="$PHP_PREFIX/bin:$PHP_PREFIX/sbin:$PATH"
        PHP_CONFIG="$PHP_PREFIX/bin/php-config"
        PHPIZE="$PHP_PREFIX/bin/phpize"
        SUDO=""
        ;;
    *)
        echo "✗ Unknown platform: $PLATFORM"
        exit 1
        ;;
esac

if [ ! -x "$PHP_CONFIG" ]; then
    echo "✗ php-config not found at $PHP_CONFIG"
    exit 1
fi

PHP_EXT_DIR="$($PHP_CONFIG --extension-dir)"
PHP_VERNUM="$($PHP_CONFIG --vernum)"
PHP_FULL="$($PHP_CONFIG --version)"

echo "  php-config : $PHP_CONFIG"
echo "  php version: $PHP_FULL (vernum $PHP_VERNUM)"
echo "  ext dir    : $PHP_EXT_DIR"

# ── opcache: bundled with PHP, just copy the .so ─────────────
echo ""
echo "──── opcache ────"
if [ -f "$PHP_EXT_DIR/opcache.so" ]; then
    cp "$PHP_EXT_DIR/opcache.so" "$EXT_DIR/opcache.so"
    echo "  ✓ opcache.so (from PHP distribution)"
else
    echo "  ⚠ opcache.so not found at $PHP_EXT_DIR/opcache.so — skipping"
fi

# ── Generic PECL build helper ────────────────────────────────
# Downloads a tarball, runs phpize/configure/make, copies the
# resulting .so. Then optionally `make install` so later extensions
# can pick up headers (needed for redis --enable-redis-igbinary etc).
#
# Args:
#   $1 name            e.g. igbinary
#   $2 url             tarball URL
#   $3 configure_args  extra flags (optional)
#   $4 install         "install" to also `make install` (optional)
build_ext() {
    local name="$1" url="$2" cfg_args="${3:-}" do_install="${4:-}"
    echo ""
    echo "──── $name ────"

    local tmp="$BUILD_DIR/ext-$name"
    rm -rf "$tmp"
    mkdir -p "$tmp"

    local tarball="$BUILD_DIR/$name.tar.gz"
    echo "  Downloading..."
    curl -fsSL -o "$tarball" "$url"
    tar xzf "$tarball" -C "$tmp" --strip-components=1

    pushd "$tmp" >/dev/null

    "$PHPIZE" >/dev/null
    # shellcheck disable=SC2086
    ./configure --with-php-config="$PHP_CONFIG" $cfg_args >/dev/null

    make -j"$JOBS" >/dev/null

    # Pick up the produced module (.so name may differ from ext name,
    # e.g. "yaml" but the folder has multiple; we take the first .so).
    local so
    so=$(find modules -maxdepth 1 -name "*.so" | head -1)
    if [ -z "$so" ] || [ ! -f "$so" ]; then
        echo "  ✗ $name: no .so produced"
        popd >/dev/null
        return 1
    fi
    cp "$so" "$EXT_DIR/"
    local sz
    sz=$(ls -lh "$so" | awk '{print $5}')
    echo "  ✓ $(basename "$so") ($sz)"

    if [ "$do_install" = "install" ]; then
        $SUDO make install >/dev/null 2>&1 || true
    fi

    popd >/dev/null
}

# Track failures but keep going so one broken ext doesn't kill the bundle.
FAILED=""
try_ext() {
    if ! build_ext "$@"; then
        FAILED="$FAILED $1"
    fi
}

# ── igbinary and msgpack first: redis/memcached can use them
#    as serializers if their headers are installed. ──────────
try_ext igbinary \
    "https://github.com/igbinary/igbinary/archive/refs/tags/${IGBINARY_VER}.tar.gz" \
    "" \
    install

try_ext msgpack \
    "https://pecl.php.net/get/msgpack-${MSGPACK_VER}.tgz" \
    "" \
    install

# ── Pure PECL extensions ─────────────────────────────────────
try_ext apcu \
    "https://github.com/krakjoe/apcu/archive/refs/tags/v${APCU_VER}.tar.gz"

try_ext yaml \
    "https://pecl.php.net/get/yaml-${YAML_VER}.tgz"

# ── redis with igbinary + msgpack serializer support ────────
try_ext redis \
    "https://github.com/phpredis/phpredis/archive/refs/tags/${REDIS_VER}.tar.gz" \
    "--enable-redis-igbinary --enable-redis-msgpack"

# ── memcached with igbinary + msgpack + json serializer ─────
try_ext memcached \
    "https://github.com/php-memcached-dev/php-memcached/archive/refs/tags/v${MEMCACHED_VER}.tar.gz" \
    "--enable-memcached-igbinary --enable-memcached-msgpack --enable-memcached-json"

# ── imagick ──────────────────────────────────────────────────
# Note: imagick 3.7.0 targets ImageMagick 6. Ubuntu's libmagickwand-dev
# ships IM6 so this works; macOS brew ships IM7 which may fail. We
# continue on error so the rest of the bundle still builds.
try_ext imagick \
    "https://pecl.php.net/get/imagick-${IMAGICK_VER}.tgz"

# ── xdebug (zend_extension) ─────────────────────────────────
try_ext xdebug \
    "https://github.com/xdebug/xdebug/archive/refs/tags/${XDEBUG_VER}.tar.gz"

# ── Write README with install instructions ──────────────────
cat > "$OUTPUT_DIR/README.txt" <<EOF
PHP $VERSION extensions for $PLATFORM
Built against: $PHP_FULL (vernum $PHP_VERNUM)
Built on     : $(date -u +%Y-%m-%dT%H:%M:%SZ)

These .so files are ABI-compatible with any PHP $VERSION.x on
the same OS / libc / glibc ABI as the build runner.
  linux-amd64  → glibc (Ubuntu 24.04 build runner)
  darwin-arm64 → macOS 14+ (Apple Silicon)

Contents:
$(ls -1 "$EXT_DIR" | sed 's/^/  /')

Install:
  1. Find your extension_dir:
       php-config --extension-dir
  2. Copy the .so files into that directory.
  3. Enable them in php.ini (or conf.d/*.ini):

       ; Zend extensions (load order matters)
       zend_extension=opcache.so
       zend_extension=xdebug.so

       ; Regular extensions
       extension=igbinary.so
       extension=msgpack.so
       extension=apcu.so
       extension=yaml.so
       extension=imagick.so
       extension=redis.so
       extension=memcached.so
EOF

echo ""
echo "══════════════════════════════════════════════"
if [ -n "$FAILED" ]; then
    echo "  ⚠ Some extensions failed to build:$FAILED"
fi
echo "  ✓ PHP $VERSION extensions for $PLATFORM"
echo "══════════════════════════════════════════════"
ls -lh "$EXT_DIR"
