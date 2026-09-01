#!/usr/bin/env bash
# Build-time: record the exact toolchain shipped in this image at
# /etc/toolchain-versions, so `docker run --rm IMG cat /etc/toolchain-versions`
# answers "which compilers?" without starting a shell.
#
# Deliberately `set -u` alone, unlike every other script here: this is a report
# over tools that are allowed to be absent, and `set -e` would turn a missing
# optional package into a failed image build. The required set is enforced by
# the sanity-check layer in each Dockerfile instead.
set -u
{
    echo "image-built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "ai-box-package: ${AI_BOX_PACKAGE_VERSION:-unknown}"
    for t in gcc g++ gcc-15 g++-15 gcc-16 g++-16 clang clang++ \
             cmake ninja ccache mold ld.lld gdb valgrind git \
             python python3 pip uv ruff mypy pytest \
             rg fd fdfind perf \
             clang-tidy clang-format cppcheck iwyu include-what-you-use \
             lcov gcovr doxygen dot \
             readelf objdump nm addr2line strings size patchelf shellcheck \
             rustc cargo go javac mvn ruby lua \
             node claude codex gemini grok; do
        command -v "$t" >/dev/null 2>&1 || continue
        # Not every tool speaks --version. graphviz's dot wants -V and prints an
        # error for --version, which would put a spurious error line in every
        # image's report; doxygen prints a bare number.
        case "$t" in
            # graphviz's dot wants -V and errors on --version.
            dot) ver="$("$t" -V 2>&1 | head -1)" ;;
            # clang-tidy prints "LLVM (http://llvm.org/):" first and the version
            # on the next line, so head -1 captured a URL and the capability
            # table then showed n/a for a tool that is installed.
            clang-tidy) ver="$("$t" --version 2>&1 | grep -m1 -iE 'version [0-9]' || "$t" --version 2>&1 | sed -n 2p)" ;;
            # lcov can emit a perl warning before its banner.
            lcov) ver="$("$t" --version 2>&1 | grep -m1 -iE 'version [0-9]' || echo unknown)" ;;
            *)   ver="$("$t" --version 2>&1 | head -1)" ;;
        esac
        ver="$(printf '%s' "$ver" | sed 's/^[[:space:]]*//')"
        printf '%-10s %s\n' "$t" "$ver"
    done
    # Static runtime archives, reported by presence rather than version: their
    # absence is what turns a -static build into "cannot find -lc", and they come
    # from separate packages on rpm distributions.
    for a in libc.a libm.a libstdc++.a libgcc.a; do
        p="$(find /usr/lib /usr/lib64 /usr/lib/gcc -name "$a" -print -quit 2>/dev/null || true)"
        [ -n "$p" ] && printf '%-10s %s\n' "static:${a%.a}" "$p"
    done
    command -v musl-gcc >/dev/null 2>&1 && printf '%-10s %s\n' musl-gcc "$(musl-gcc --version 2>&1 | head -1)"
} > /etc/toolchain-versions
cat /etc/toolchain-versions
