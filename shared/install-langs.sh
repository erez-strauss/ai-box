#!/usr/bin/env bash
# Install optional language toolchains into the image.
#
# Called from every Dockerfile with the value of the LANGS build arg, which is
# EMPTY by default. C++ and Python are not in this list: they are the base image
# and are always present.
#
#   scripts/build.sh --lang rust,go fedora
#   scripts/build.sh --from-registry --lang rust all
#
# What this is, and what it is not.
#
# It is a convenience over "edit the Dockerfile and rebuild", using the same
# optional-package machinery as everything else: distro packages, installed with
# --skip-unavailable on dnf or one at a time on apt, so a name that has moved
# logs a note instead of breaking the image (hard rule 9).
#
# It is NOT a promise of first-class support per language. The project's identity
# is C++ and Python done properly; breadth is another project's job. What this
# gives you is a supported seam instead of a fork, and a place to read what the
# package names are on each distribution.
#
# Everything here comes from the distribution's own signed repositories. That is
# deliberate and it has a cost worth knowing: distro toolchains lag upstream, and
# for Rust in particular the gap can be large. The upstream installer is
# `curl https://sh.rustup.rs | sh`, which this project will not run during an
# image build for the same reason it refuses the agent vendors' installers. If
# you need a specific Rust, install rustup into your *project* at run time, where
# it is your decision and not a property of the image:
#
#   ai-box -- bash -lc 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
#       | sh -s -- --no-modify-path -y'
#
# and keep it under /workspace so it persists with the project.
set -euo pipefail

if [[ -z "${AI_BOX_BUILD:-}" ]]; then
    echo "FATAL: install-langs.sh is run by the image build, not by hand." >&2
    echo "       It installs system packages. To add a language to an image:" >&2
    echo "         ai-box-build --lang <list> <image>" >&2
    exit 1
fi

LANGS="${1:-}"
[[ -n "$LANGS" && "$LANGS" != none ]] || { echo "no optional languages requested"; exit 0; }

KNOWN_LANGS=(rust go java node ruby lua)

if [[ "$LANGS" == "all" ]]; then
    LANGS="$(IFS=,; echo "${KNOWN_LANGS[*]}")"
    echo "languages: all -> ${LANGS}"
fi

have() { command -v "$1" >/dev/null 2>&1; }

# Package names per language, per family. Kept in one table rather than spread
# through three Dockerfiles, because the whole difficulty of this feature is that
# the names differ and drift.
#
# rpm covers Fedora and Rocky; some of these live in EPEL or CRB on Rocky, which
# the image already enables, and --skip-unavailable absorbs the rest.
packages_for() {
    local lang="$1" family="$2"
    case "${lang}/${family}" in
        rust/deb)  echo "rustc cargo rust-src rustfmt" ;;
        rust/rpm)  echo "rust cargo rust-src rustfmt clippy" ;;
        go/deb)    echo "golang-go" ;;
        go/rpm)    echo "golang" ;;
        java/deb)  echo "default-jdk maven" ;;
        java/rpm)  echo "java-latest-openjdk-devel maven" ;;
        node/deb)  echo "nodejs npm" ;;
        node/rpm)  echo "nodejs npm nodejs-full-i18n" ;;
        ruby/deb)  echo "ruby ruby-dev" ;;
        ruby/rpm)  echo "ruby ruby-devel rubygems" ;;
        lua/deb)   echo "lua5.4 liblua5.4-dev luarocks" ;;
        lua/rpm)   echo "lua lua-devel luarocks" ;;
        *)         return 1 ;;
    esac
}

if have dnf; then FAMILY=rpm; elif have apt-get; then FAMILY=deb; else
    echo "FATAL: no supported package manager" >&2; exit 1
fi

install_pkgs() {
    if [[ "$FAMILY" == rpm ]]; then
        dnf -y --setopt=install_weak_deps=False --nodocs --skip-unavailable install "$@" \
            || for p in "$@"; do
                   dnf -y --setopt=install_weak_deps=False --nodocs install "$p" \
                       || echo "optional package unavailable, skipped: $p"
               done
        dnf clean all; rm -rf /var/cache/dnf
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        for p in "$@"; do
            apt-get install -y --no-install-recommends "$p" \
                || echo "optional package unavailable, skipped: $p"
        done
        rm -rf /var/lib/apt/lists/*
    fi
}

IFS=',' read -ra _wanted <<< "$LANGS"
for l in "${_wanted[@]}"; do
    lang="$(echo "$l" | tr -d '[:space:]')"
    [[ -n "$lang" ]] || continue
    case "$lang" in
        c++|cpp|python)
            echo "note: $lang is part of the base image and is always present; ignoring" ;;
        *)
            pkgs="$(packages_for "$lang" "$FAMILY")" \
                || { echo "FATAL: unknown language '$lang' (known: ${KNOWN_LANGS[*]}, or 'all')" >&2; exit 1; }
            echo "installing $lang: $pkgs"
            # shellcheck disable=SC2086  # the list is intentionally word-split
            install_pkgs $pkgs ;;
    esac
done

# Report what actually landed. A language whose packages were all skipped is a
# silent no-op otherwise, which is the failure mode hard rule 9 keeps producing.
echo "--- language toolchains present ---"
for t in rustc cargo go javac mvn node ruby lua; do
    if have "$t"; then printf '%-8s %s\n' "$t" "$("$t" --version 2>&1 | head -1)"; fi
done
