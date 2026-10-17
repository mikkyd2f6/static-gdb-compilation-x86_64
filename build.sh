#!/usr/bin/env bash
#
# Build statically-linked GDB for x86_64 Linux.
#
# Produces two variants (configure which via VARIANTS):
#   nopython : lean debugger, no Python scripting
#   python   : embeds a from-source static CPython for GDB Python scripting
#
# Outputs:
#   dist/gdb-<ver>-static-<variant>   stripped, portable static binaries
#   install/<variant>/                full install trees (bin/, share/gdb/, ...)
#
# See README.md for requirements and known caveats.
#
set -euo pipefail

GDB_VERSION="${GDB_VERSION:-16.3}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12.7}"
TARGETS="${TARGETS:-all}"                  # "all" or e.g. x86_64-linux-gnu
VARIANTS="${VARIANTS:-nopython python}"    # space-separated subset
JOBS="${JOBS:-$(nproc)}"

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$BASE/src"
DEPS="$BASE/deps"
DIST="$BASE/dist"
mkdir -p "$SRC" "$DEPS" "$DIST"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

# --------------------------------------------------------------------------
# 0. Host dependencies
# --------------------------------------------------------------------------
check_host_deps() {
    local missing_pkgs=()
    local header

    for header in \
        "/usr/include/expat.h:libexpat1-dev" \
        "/usr/include/zlib.h:zlib1g-dev" \
        "/usr/include/mpfr.h:libmpfr-dev" \
        "/usr/lib/x86_64-linux-gnu/libtinfo.a:libncurses-dev"
    do
        [ -e "${header%%:*}" ] || missing_pkgs+=("${header##*:}")
    done
    # GMP header lives at a multiarch path on Ubuntu/Debian
    if [ ! -e /usr/include/gmp.h ] && [ ! -e /usr/include/x86_64-linux-gnu/gmp.h ]; then
        missing_pkgs+=(libgmp-dev)
    fi
    command -v makeinfo >/dev/null || missing_pkgs+=(texinfo)

    if [ "${#missing_pkgs[@]}" -gt 0 ]; then
        echo "Missing host packages: ${missing_pkgs[*]}" >&2
        echo "Install them with:" >&2
        echo "  sudo apt-get install -y ${missing_pkgs[*]}" >&2
        exit 1
    fi
}

# --------------------------------------------------------------------------
# 1. Fetch and unpack sources
# --------------------------------------------------------------------------
fetch_sources() {
    cd "$SRC"

    if [ ! -d "gdb-$GDB_VERSION" ]; then
        log "Downloading GDB $GDB_VERSION"
        [ -f "gdb-$GDB_VERSION.tar.xz" ] || \
            curl -fsSLO "https://ftp.gnu.org/gnu/gdb/gdb-$GDB_VERSION.tar.xz"
        tar xf "gdb-$GDB_VERSION.tar.xz"
    fi

    if [[ " $VARIANTS " == *" python "* ]] && [ ! -d "Python-$PYTHON_VERSION" ]; then
        log "Downloading Python $PYTHON_VERSION"
        [ -f "Python-$PYTHON_VERSION.tgz" ] || \
            curl -fsSLO "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz"
        tar xf "Python-$PYTHON_VERSION.tgz"
    fi
    cd "$BASE"
}

# --------------------------------------------------------------------------
# 2. Static CPython (works around distro libpython3.x.a being un-linkable
#    statically: Ubuntu ships undefined python_hashlib_Hacl_* symbols and
#    embeds pyexpat/zlib without extra link flags)
# --------------------------------------------------------------------------
build_static_python() {
    [ -x "$DEPS/python/bin/python3" ] && { log "Static Python already built"; return; }

    log "Building static CPython $PYTHON_VERSION"
    cd "$SRC/Python-$PYTHON_VERSION"
    ./configure --prefix="$DEPS/python" --disable-shared --without-ensurepip
    make -j"$JOBS"
    make install
    cd "$BASE"
}

# --------------------------------------------------------------------------
# 3. GDB variant build
# --------------------------------------------------------------------------
build_variant() {
    local name="$1" extra_config="$2"
    local bdir="$BASE/build-$name"
    local prefix="$BASE/install/$name"

    log "Building GDB $GDB_VERSION variant '$name' (targets: $TARGETS)"
    mkdir -p "$bdir"
    cd "$bdir"

    # LDFLAGS=-static makes configure's link tests run statically (this also
    # validates static Python embedding early for the python variant).
    # shellcheck disable=SC2086
    "$SRC/gdb-$GDB_VERSION/configure" \
        --prefix="$prefix" \
        --enable-targets="$TARGETS" \
        $extra_config \
        --without-guile \
        --disable-nls \
        LDFLAGS="-static"

    make -j"$JOBS" all-gdb

    # GDB's final link goes through libtool, which silently consumes a plain
    # "-static" and produces a *dynamic* binary. Relink fully static:
    rm -f gdb/gdb
    make -C gdb LDFLAGS="-all-static"

    make -C gdb install
    cd "$BASE"

    cp "$prefix/bin/gdb" "$DIST/gdb-$GDB_VERSION-static-$name"
    strip "$DIST/gdb-$GDB_VERSION-static-$name"
}

# --------------------------------------------------------------------------
# 4. Sanity check the results
# --------------------------------------------------------------------------
verify() {
    log "Results"
    local b
    shopt -s nullglob
    for b in "$DIST"/gdb-*-static-*; do
        file "$b" | sed 's/^/  /'
        "$b" --version | head -1 | sed 's/^/  /'
    done
    shopt -u nullglob
}

main() {
    check_host_deps
    fetch_sources

    for variant in $VARIANTS; do
        case "$variant" in
            nopython)
                build_variant nopython "--without-python" ;;
            python)
                build_static_python
                build_variant python "--with-python=$DEPS/python/bin/python3" ;;
            *)
                echo "Unknown variant: $variant (expected nopython or python)" >&2
                exit 1 ;;
        esac
    done

    verify
    log "Done. Binaries in $DIST"
}

main "$@"
