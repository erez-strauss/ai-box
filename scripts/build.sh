#!/usr/bin/env bash
# Build one or both ai-box images from the package root.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

require_host

TARGETS=()
CLAUDE_VERSION=""
LLVM_VERSION="${AI_BOX_LLVM_VERSION:-22}"
LLVM_UPSTREAM=""
TOOLCHAIN="${AI_BOX_TOOLCHAIN:-newest}"
# Empty means "let the Dockerfile decide", which is `latest`. Defaulting to a
# number here silently overrode that and pinned every Ubuntu image to GCC 15.
GCC_DEFAULT="${AI_BOX_GCC_DEFAULT:-}"
CHANNEL="stable"
OS_UPDATES=1
OS_TAG=""
PULL_BASE=0
BASE_TAG=""
AI_AGENTS=""
LANGS=""
WITH_NODE=""
PYTHON_TOOLS=""
UV_PYTHON=""
EXTRA=()
TARGET_ARG=""

usage() {
    cat <<'USAGE'
usage: build.sh [ubuntu|fedora|rocky|all] [options]

  OS freshness (default: apply every pending distro update)
    --no-updates       do NOT upgrade packages; take them exactly as the base
                       image tag shipped them. Use with --os-tag for a
                       reproducible rebuild of a known-good image.
    -t, --os-tag TAG   base image tag to build from, e.g. 26.04, 26.04.1,
                       rolling, or a digest "26.04@sha256:...". Defaults to the
                       tag pinned in the Dockerfile.

  Toolchain (policy: newest obtainable, not merely what the distro packages)
    --toolchain newest|distro
                       newest (default) takes the newest compilers obtainable,
                       which on Ubuntu means Clang from apt.llvm.org because the
                       archive trails a major version. distro restricts the image
                       to the distribution's own signed repositories: one fewer
                       third-party key, an older Clang.
    -g, --gcc VERSION  pin which GCC the unversioned gcc/g++ point at in the Ubuntu
                       image. Default: the newest one installed, which is the
                       policy for every image.
    -L, --llvm-upstream  Ubuntu only: Clang from apt.llvm.org, not the archive
    -l, --llvm-version VERSION   LLVM major to use with -L (default 22)

  Optional AI agents (none are installed by default)
    --agents LIST      comma-separated: codex, gemini, grok -- or `all` for every
                       agent this package knows how to install, or `none` (the
                       default). Only codex ships a native Linux binary; gemini
                       and grok are npm packages and pull Node into the image.
                       Claude Code is always installed regardless, from
                       Anthropic's signed repository.
    --with-node        install Node even when no npm-based agent was requested

  Language toolchains (C++ and Python are always present)
    --lang LIST        comma-separated: rust, go, java, node, ruby, lua, or
                       `all`. Distro packages only, installed as optional
                       leaves, so a name that has moved logs a note rather than
                       breaking the build. See shared/install-langs.sh for the
                       per-distro package names and for why rustup is not used.

  Python
    --python-tools "PKGS"   packages for the image virtualenv at /opt/venv
                       (default: uv ruff mypy pytest pytest-cov ipython build
                       wheel jinja2 numpy pandas)
    --uv-python VERSION     also bake a standalone interpreter of this version
                       into the image via uv, e.g. 3.13

  Claude Code
    -c, --claude-version VERSION   pin an exact version; also busts the layer
                       cache for the install step
    -C, --channel CHANNEL          stable (default) or latest

  Publishing
    --from-registry    derive from the published base image instead of building
                       from source: pull it, apply package updates, install the
                       agents from --agents, match your UID, and tag it locally.
                       Seconds rather than a full build. Published bases carry no
                       optional agents by design. (Distinct from -p/--pull,
                       which refreshes the base of a from-source build.)
    --base-tag TAG     which published tag to derive from (default: this
                       package's version, then `latest`)

  Docker
    -n, --no-cache     pass --no-cache
    -p, --pull         refresh the base image (implied unless --no-updates)
    -h, --help

By default every build applies pending OS updates and pulls a fresh base image,
so images do not silently rot. --no-updates gives up freshness for
reproducibility; pair it with --os-tag and a pinned --claude-version to rebuild
a specific historical image.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-updates)          OS_UPDATES=0; shift ;;
        -t|--os-tag)           OS_TAG="${2:?--os-tag needs a value}"; shift 2 ;;
        --os-tag=*)            OS_TAG="${1#*=}"; shift ;;
        -g|--gcc)              GCC_DEFAULT="${2:?}"; GCC_DEFAULT_SET=1; shift 2 ;;
        --gcc=*)               GCC_DEFAULT="${1#*=}"; GCC_DEFAULT_SET=1; shift ;;
        --toolchain)           TOOLCHAIN="${2:?}"; shift 2 ;;
        --toolchain=*)         TOOLCHAIN="${1#*=}"; shift ;;
        -L|--llvm-upstream)    LLVM_UPSTREAM=1; shift ;;
        -l|--llvm-version)     LLVM_VERSION="${2:?}"; LLVM_UPSTREAM=1; shift 2 ;;
        --llvm-version=*)      LLVM_VERSION="${1#*=}"; LLVM_UPSTREAM=1; shift ;;
        --lang)                LANGS="${2:?}"; shift 2 ;;
        --lang=*)              LANGS="${1#*=}"; shift ;;
        --agents)              AI_AGENTS="${2:?}"; shift 2 ;;
        --agents=*)            AI_AGENTS="${1#*=}"; shift ;;
        --with-node)           WITH_NODE=1; shift ;;
        --python-tools)        PYTHON_TOOLS="${2:?}"; shift 2 ;;
        --python-tools=*)      PYTHON_TOOLS="${1#*=}"; shift ;;
        --uv-python)           UV_PYTHON="${2:?}"; shift 2 ;;
        --uv-python=*)         UV_PYTHON="${1#*=}"; shift ;;
        -c|--claude-version)   CLAUDE_VERSION="${2:?}"; shift 2 ;;
        --claude-version=*)    CLAUDE_VERSION="${1#*=}"; shift ;;
        -C|--channel)          CHANNEL="${2:?}"; shift 2 ;;
        --channel=*)           CHANNEL="${1#*=}"; shift ;;
        --from-registry)       PULL_BASE=1; shift ;;
        --base-tag)            BASE_TAG="${2:?}"; shift 2 ;;
        --base-tag=*)          BASE_TAG="${1#*=}"; shift ;;
        -n|--no-cache)         EXTRA+=(--no-cache); shift ;;
        -p|--pull)             EXTRA+=(--pull); shift ;;
        -h|--help)             usage; exit 0 ;;
        ubuntu|fedora|rocky|all) TARGET_ARG="$1"; shift ;;
        --)                    shift ;;
        -*)                    die "unknown option: $1 (try --help)" ;;
        *)                     die "unexpected argument: $1" ;;
    esac
done

# Reject an unknown language now rather than after a long build.
if [[ -n "$LANGS" && "$LANGS" != all && "$LANGS" != none ]]; then
    IFS=',' read -ra _langs <<< "$LANGS"
    for _l in "${_langs[@]}"; do
        case "${_l// /}" in
            rust|go|java|node|ruby|lua|'') ;;
            c++|cpp|python) warn "${_l// /} is part of the base image; ignoring it in --lang" ;;
            *) die "unknown language: ${_l// /} (known: rust, go, java, node, ruby, lua, all)" ;;
        esac
    done
    unset _langs _l
fi

# Reject an unknown agent now rather than after a twenty-minute image build.
if [[ -n "$AI_AGENTS" && "$AI_AGENTS" != all && "$AI_AGENTS" != none ]]; then
    IFS=',' read -ra _requested <<< "$AI_AGENTS"
    for _a in "${_requested[@]}"; do
        case "${_a// /}" in
            codex|gemini|grok|'') ;;
            claude) warn "claude-code is always installed; ignoring 'claude' in --agents" ;;
            *) die "unknown agent: ${_a// /} (known: codex, gemini, grok, all, none)" ;;
        esac
    done
    unset _requested _a
fi

case "$TOOLCHAIN" in
    newest|distro) ;;
    *) die "unknown --toolchain: $TOOLCHAIN (expected newest or distro)" ;;
esac

case "${TARGET_ARG:-all}" in
    all)    TARGETS=("${ALL_IMAGE_KEYS[@]}") ;;
    ubuntu) TARGETS=(ubuntu) ;;
    fedora) TARGETS=(fedora) ;;
    rocky)  TARGETS=(rocky) ;;
esac

# Toolchain selection is Ubuntu-only: the Fedora image takes whatever compilers
# Fedora ships. Say so rather than silently ignoring the flag.
if [[ "${TARGET_ARG:-}" == fedora || "${TARGET_ARG:-}" == rocky ]]; then
    if [[ -n "${GCC_DEFAULT_SET:-}" ]]; then
        warn "-g/--gcc applies to the Ubuntu image only. Fedora uses Fedora's GCC; Rocky selects a gcc-toolset (--build-arg GCC_TOOLSET=N). Ignoring."
    fi
    if [[ -n "$LLVM_UPSTREAM" ]]; then
        warn "-L/-l apply to the Ubuntu image only. Ignoring."
    fi
fi

# Updates on (the default) means: pull a fresh base image, and change
# UPDATE_STAMP so Docker cannot reuse a stale "dist-upgrade" layer. Without the
# stamp, the upgrade would run once and then be cached indefinitely.
if (( OS_UPDATES )); then
    UPDATE_STAMP="$(date -u +%Y-%m-%d)"
    case " ${EXTRA[*]-} " in *" --pull "*) ;; *) EXTRA+=(--pull) ;; esac
else
    UPDATE_STAMP="static"
fi

require_engine
cd "$PKG_ROOT"

# --- derive from a published base -------------------------------------------
if (( PULL_BASE )); then
    tag="${BASE_TAG:-$PKG_VERSION}"
    for key in "${TARGETS[@]}"; do
        ref="$(image_ref "$key")"
        base="$(registry_ref "$key"):${tag}"

        log "pulling $base"
        if ! "$ENGINE" pull "$base"; then
            if [[ -z "$BASE_TAG" ]]; then
                base="$(registry_ref "$key"):latest"
                warn "no published image tagged ${tag}; trying ${base}"
                "$ENGINE" pull "$base" || pull_failed=1
            else
                pull_failed=1
            fi
        fi
        if [[ "${pull_failed:-0}" == 1 ]]; then
            # A missing published image is the most likely first-run failure, and
            # "could not pull" alone leaves the user stuck. The local build is
            # always available and needs no registry at all.
            printf '\033[1;31merror:\033[0m no published image for %s at %s\n' "$key" "$base" >&2
            printf '       The images may not be published yet, the registry may be\n' >&2
            printf '       unreachable, or AI_BOX_REGISTRY may point somewhere else\n' >&2
            printf '       (currently: %s).\n\n' "$REGISTRY" >&2
            printf '       Build it locally instead, which needs no registry:\n' >&2
            printf '         scripts/build.sh %s\n\n' "$key" >&2
            printf '       One image takes roughly 10-15 minutes; all three about 35.\n' >&2
            exit 1
        fi

        # A tag is mutable, so record the digest actually used. Without it a
        # derive from a re-pushed tag is indistinguishable from a stale one.
        digest="$("$ENGINE" image inspect "$base" \
            --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
        [[ -n "$digest" ]] && log "base digest: $digest"

        log "deriving $ref from $base  [agents: ${AI_AGENTS:-none}, OS updates: ${OS_UPDATES}]"
        "$ENGINE" build \
            --file docker-derive/Dockerfile.derive \
            --tag "$ref" \
            --build-arg "BASE_IMAGE=${base}" \
            --build-arg "AI_AGENTS=${AI_AGENTS}" \
            --build-arg "LANGS=${LANGS}" \
            --build-arg "WITH_NODE=${WITH_NODE:-0}" \
            --build-arg "CODEX_VERSION=${CODEX_VERSION:-}" \
            --build-arg "CODEX_SHA256=${CODEX_SHA256:-}" \
            --build-arg "OS_UPDATES=${OS_UPDATES}" \
            --build-arg "UPDATE_STAMP=${UPDATE_STAMP}" \
            --build-arg "UID=$(id -u)" \
            --build-arg "GID=$(id -g)" \
            --build-arg "PACKAGE_VERSION=${PKG_VERSION}" \
            "${EXTRA[@]+"${EXTRA[@]}"}" \
            "$PKG_ROOT"

        cc="$(installed_claude_version "$ref")"
        [[ -n "$cc" && "$cc" != "-" ]] && "$ENGINE" tag "$ref" "${ref}-cc${cc}"
        "$ENGINE" tag "$ref" "${ref}-pkg${PKG_VERSION}"
        log "$ref ready from a published base (Claude Code ${cc})"
    done

    log "done. Toolchain report:"
    for key in "${TARGETS[@]}"; do
        printf '\n--- %s ---\n' "$(image_ref "$key")"
        "$ENGINE" run --rm "$(image_ref "$key")" cat /etc/toolchain-versions
    done
    exit 0
fi

for key in "${TARGETS[@]}"; do
    ref="$(image_ref "$key")"
    if (( OS_UPDATES )); then
        log "building $ref  [package $PKG_VERSION, OS updates ON, stamp ${UPDATE_STAMP}]"
    else
        log "building $ref  [package $PKG_VERSION, OS updates OFF (reproducible)]"
    fi
    if [[ -n "$OS_TAG" ]]; then log "  base image tag: ${OS_TAG}"; fi

    args=(
        --file "$(dockerfile_for "$key")"
        --tag "$ref"
        --build-arg "UID=$(id -u)"
        --build-arg "GID=$(id -g)"
        --build-arg "CLAUDE_CHANNEL=${CHANNEL}"
        --build-arg "CLAUDE_VERSION=${CLAUDE_VERSION}"
        --build-arg "PACKAGE_VERSION=${PKG_VERSION}"
        --build-arg "OS_UPDATES=${OS_UPDATES}"
        --build-arg "UPDATE_STAMP=${UPDATE_STAMP}"
    )
    if [[ -n "$OS_TAG" ]]; then
        args+=(--build-arg "OS_TAG=${OS_TAG}")
    fi
    if [[ -n "$AI_AGENTS" ]]; then
        args+=(--build-arg "AI_AGENTS=${AI_AGENTS}")
    fi
    if [[ -n "$LANGS" ]]; then
        args+=(--build-arg "LANGS=${LANGS}")
    fi
    if [[ -n "$WITH_NODE" ]]; then
        args+=(--build-arg "WITH_NODE=${WITH_NODE}")
    fi
    if [[ -n "$PYTHON_TOOLS" ]]; then
        args+=(--build-arg "PYTHON_TOOLS=${PYTHON_TOOLS}")
    fi
    if [[ -n "$UV_PYTHON" ]]; then
        args+=(--build-arg "UV_PYTHON=${UV_PYTHON}")
    fi
    if [[ "$key" == ubuntu ]]; then
        args+=(
            --build-arg "TOOLCHAIN=${TOOLCHAIN}"
            --build-arg "LLVM_VERSION=${LLVM_VERSION}"
        )
        # Only pass the override when the caller asked for one; otherwise the
        # Dockerfile derives it from TOOLCHAIN.
        if [[ -n "$LLVM_UPSTREAM" ]]; then
            args+=(--build-arg "LLVM_FROM_UPSTREAM=${LLVM_UPSTREAM}")
        fi
        if [[ -n "$GCC_DEFAULT" ]]; then
            args+=(--build-arg "GCC_DEFAULT=${GCC_DEFAULT}")
        fi
    fi

    "$ENGINE" build "${args[@]}" "${EXTRA[@]+"${EXTRA[@]}"}" .

    cc="$(installed_claude_version "$ref")"
    if [[ -n "$cc" && "$cc" != "-" ]]; then
        "$ENGINE" tag "$ref" "${ref}-cc${cc}"
        log "tagged ${ref}-cc${cc}"
    fi
    "$ENGINE" tag "$ref" "${ref}-pkg${PKG_VERSION}"
    log "$ref ready  (Claude Code ${cc}, package ${PKG_VERSION})"
done

log "done. Toolchain report:"

for key in "${TARGETS[@]}"; do
    printf '\n--- %s ---\n' "$(image_ref "$key")"
    "$ENGINE" run --rm "$(image_ref "$key")" cat /etc/toolchain-versions
done
