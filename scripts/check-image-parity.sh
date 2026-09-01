#!/usr/bin/env bash
# Assert that every Dockerfile still implements the shared contract.
#
# Hard rule 10 says the images must be behaviourally equivalent: same entrypoint,
# same user, same paths, same environment variable names. That was prose, and
# prose does not fail a build. 2.0.0 shipped a Rocky image with no Python venv,
# no sanity check, and a surviving reference to ${VIRTUAL_ENV} -- it had been
# scaffolded from the Fedora file by replacing a region that turned out to span
# two more blocks than intended. Nothing caught it until the image was built.
#
# This is a structural check, not a build: it greps for the markers each image
# must define, and for variables used but never set.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

# Marker -> what its absence would mean.
REQUIRED=(
    'ENV VIRTUAL_ENV=|the Python virtualenv the entrypoint and PATH depend on'
    'ARG PYTHON_TOOLS=|the configurable Python package set'
    'ARG AI_AGENTS=|opt-in third-party agents'
    'ARG CACHE_KEY=|per-image cache directory naming'
    'ARG OS_UPDATES=|the updates-by-default switch'
    'ARG UPDATE_STAMP=|the cache-buster that keeps OS_UPDATES meaningful'
    'COPY --chmod=0755 shared/entrypoint.sh|the shared entrypoint'
    'COPY --chmod=0644 shared/keyfile-lib.sh|the single key parser'
    'install -d -m 0755 /usr/local/lib/ai-box|explicit dir mode, see hard rule 20'
    'ENTRYPOINT \["/usr/local/bin/entrypoint.sh"\]|the entrypoint'
    'USER \$\{USERNAME\}|dropping from root'
    'WORKDIR /workspace|the project mount point'
    'CCACHE_DIR=/workspace|caches in the workspace, not a side mount'
    'XDG_CACHE_HOME=/workspace|the same, for tools that honour XDG'
    'test -z "\$\(ls -A /workspace\)"|/workspace must be empty in the image'
    'FATAL: venv tool|the unprivileged sanity check'
)

rc=0
shopt -s nullglob
for df in docker-*/Dockerfile.*; do
    # Dockerfile.derive is an overlay on a finished image, not an image
    # definition: no entrypoint, no user creation, no cache layout, all
    # inherited. Holding it to the full contract would be meaningless.
    [[ "$(basename "$df")" == Dockerfile.derive ]] && continue
    name="$(basename "$df")"
    problems=()

    for spec in "${REQUIRED[@]}"; do
        pattern="${spec%%|*}"; why="${spec#*|}"
        grep -qE -- "$pattern" "$df" || problems+=("missing: $why  [$pattern]")
    done

    # A variable interpolated but never declared is what broke the Rocky build:
    # `chown ... "${VIRTUAL_ENV}"` with no ENV VIRTUAL_ENV, which fails only at
    # build time, several minutes in.
    while IFS= read -r var; do
        case "$var" in
            # Shell-local or provided by the base image, not Dockerfile-declared.
            PATH|HOME|LD_LIBRARY_PATH|TMPDIR|_*|GT|LT|OPTIONAL|v|t|d|p|f) continue ;;
        esac
        grep -qE "^(ARG|ENV) +${var}[= ]|^ *${var}=" "$df" \
            || grep -qE "^(ARG|ENV).*[[:space:]]${var}=" "$df" \
            || problems+=("uses \${${var}} but never declares it")
    done < <(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "$df" | tr -d '${}' | sort -u)

    if (( ${#problems[@]} )); then
        printf '\033[31mFAIL\033[0m %s\n' "$name"
        printf '       %s\n' "${problems[@]}"
        rc=1
    else
        printf '\033[32m ok \033[0m %s\n' "$name"
    fi
done
shopt -u nullglob

(( rc == 0 )) && log "all images implement the shared contract" \
              || die "image contract violated; see above"

# The toolchain report is how anyone discovers what an image has. A package that
# is installed but never probed is invisible, which is how graphviz, doxygen and
# the binutils front-ends sat in the images unreported: the edit that was meant
# to add them to the probe list silently matched nothing.
REPORT="$PKG_ROOT/shared/toolchain-report.sh"
unreported=()
for tool in cppcheck lcov gcovr doxygen dot readelf objdump nm patchelf \
            clang-tidy clang-format; do
    grep -qE "(^|[[:space:]])${tool}([[:space:]]|\\\\|;)" "$REPORT" \
        || unreported+=("$tool")
done
if (( ${#unreported[@]} )); then
    printf '\033[31mFAIL\033[0m %s\n' "shared/toolchain-report.sh"
    printf '       installed but never probed: %s\n' "${unreported[*]}"
    die "a tool the images install is invisible in the toolchain report"
fi
log "toolchain report probes every tool the images install"
