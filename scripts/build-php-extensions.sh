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
case "$VERSION" in
    8.1|8.2|8.3|8.4) IGBINARY_VER="3.2.16" ;;
    *)               IGBINARY_VER="3.2.17RC1" ;;  # PHP 8.5+ support
esac
APCU_VER="5.1.24"
case "$VERSION" in
    8.1|8.2|8.3|8.4) YAML_VER="2.2.4" ;;
    *)               YAML_VER="2.3.0" ;;  # PHP 8.5+ support
esac
MSGPACK_VER="2.2.0RC2"
case "$VERSION" in
    8.1|8.2|8.3|8.4) REDIS_VER="6.2.0" ;;
    *)               REDIS_VER="6.3.0" ;;  # PHP 8.5+ support
esac
MEMCACHED_VER="3.3.0"

# imagick: 3.7.0 misbuilds on PHP 8.4+; 3.8.0 adds 8.4 support.
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
            "php${VERSION}-cli" "php${VERSION}-dev" \
            build-essential autoconf pkg-config re2c bison \
            libmagickwand-dev libmemcached-dev libyaml-dev \
            libssl-dev zlib1g-dev
        # php-opcache is a separate package on older versions but bundled in
        # newer ones (e.g. PHP 8.5 on ondrej/php). Install if available.
        sudo apt-get install -y -qq "php${VERSION}-opcache" 2>/dev/null || \
            echo "  (php${VERSION}-opcache package not available — opcache.so may be bundled with php-cli)"
        PHP_CONFIG="/usr/bin/php-config${VERSION}"
        PHPIZE="/usr/bin/phpize${VERSION}"
        SUDO="sudo"
        LIBYAML_PREFIX="/usr"
        ;;
    darwin-arm64)
        echo ""
        echo "[setup] Installing PHP $VERSION dev toolchain + native deps..."
        brew update >/dev/null
        # shellcheck disable=SC2086
        brew install \
            "php@${VERSION}" \
            autoconf pkg-config re2c bison pcre2 \
            imagemagick libmemcached libyaml openssl@3 zlib 2>/dev/null || true
        PHP_PREFIX="$(brew --prefix "php@${VERSION}")"
        export PATH="$PHP_PREFIX/bin:$PHP_PREFIX/sbin:$PATH"
        PHP_CONFIG="$PHP_PREFIX/bin/php-config"
        PHPIZE="$PHP_PREFIX/bin/phpize"
        SUDO=""

        # Homebrew's php@x includes <pcre2.h> from its public headers but
        # doesn't ship the pcre2 headers itself. Wire brew's pcre2 include
        # and lib paths into the compiler env so extension builds find it.
        PCRE2_PREFIX="$(brew --prefix pcre2)"
        OPENSSL_PREFIX="$(brew --prefix openssl@3)"
        ZLIB_PREFIX="$(brew --prefix zlib)"
        LIBYAML_PREFIX="$(brew --prefix libyaml)"
        LIBMEMCACHED_PREFIX="$(brew --prefix libmemcached)"
        IMAGEMAGICK_PREFIX="$(brew --prefix imagemagick)"
        export CPPFLAGS="-I${PCRE2_PREFIX}/include -I${OPENSSL_PREFIX}/include -I${ZLIB_PREFIX}/include -I${LIBYAML_PREFIX}/include -I${LIBMEMCACHED_PREFIX}/include -I${IMAGEMAGICK_PREFIX}/include ${CPPFLAGS:-}"
        export LDFLAGS="-L${PCRE2_PREFIX}/lib -L${OPENSSL_PREFIX}/lib -L${ZLIB_PREFIX}/lib -L${LIBYAML_PREFIX}/lib -L${LIBMEMCACHED_PREFIX}/lib -L${IMAGEMAGICK_PREFIX}/lib ${LDFLAGS:-}"
        export PKG_CONFIG_PATH="${PCRE2_PREFIX}/lib/pkgconfig:${OPENSSL_PREFIX}/lib/pkgconfig:${ZLIB_PREFIX}/lib/pkgconfig:${LIBYAML_PREFIX}/lib/pkgconfig:${LIBMEMCACHED_PREFIX}/lib/pkgconfig:${IMAGEMAGICK_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
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
#
# Fails hard (set -e) if the extension fails to build. The whole
# bundle is all-or-nothing: we don't want to ship a partial release.
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

    # Pick up the produced module (.so name may differ from ext name).
    local so
    so=$(find modules -maxdepth 1 -name "*.so" | head -1)
    if [ -z "$so" ] || [ ! -f "$so" ]; then
        echo "  ✗ $name: no .so produced"
        exit 1
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

# ── igbinary and msgpack first: redis/memcached can use them
#    as serializers if their headers are installed. ──────────
build_ext igbinary \
    "https://github.com/igbinary/igbinary/archive/refs/tags/${IGBINARY_VER}.tar.gz" \
    "" \
    install

build_ext msgpack \
    "https://pecl.php.net/get/msgpack-${MSGPACK_VER}.tgz" \
    "" \
    install

# ── Pure PECL extensions ─────────────────────────────────────
build_ext apcu \
    "https://github.com/krakjoe/apcu/archive/refs/tags/v${APCU_VER}.tar.gz"

build_ext yaml \
    "https://pecl.php.net/get/yaml-${YAML_VER}.tgz" \
    "--with-yaml=${LIBYAML_PREFIX}"

# ── redis with igbinary + msgpack serializer support ────────
build_ext redis \
    "https://github.com/phpredis/phpredis/archive/refs/tags/${REDIS_VER}.tar.gz" \
    "--enable-redis-igbinary --enable-redis-msgpack"

# ── memcached with igbinary + msgpack + json serializer ─────
MEMCACHED_CFG="--enable-memcached-igbinary --enable-memcached-msgpack --enable-memcached-json"
if [ "$PLATFORM" = "darwin-arm64" ]; then
    MEMCACHED_CFG="$MEMCACHED_CFG --with-libmemcached-dir=${LIBMEMCACHED_PREFIX} --with-zlib-dir=${ZLIB_PREFIX}"
fi
build_ext memcached \
    "https://github.com/php-memcached-dev/php-memcached/archive/refs/tags/v${MEMCACHED_VER}.tar.gz" \
    "$MEMCACHED_CFG"

# ── imagick ──────────────────────────────────────────────────
build_ext imagick \
    "https://pecl.php.net/get/imagick-${IMAGICK_VER}.tgz"

# ── xdebug (zend_extension) ─────────────────────────────────
build_ext xdebug \
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
echo "  ✓ PHP $VERSION extensions for $PLATFORM"
echo "══════════════════════════════════════════════"
ls -lh "$EXT_DIR"
