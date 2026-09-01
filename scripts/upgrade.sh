#!/usr/bin/env bash
# Upgrade the Claude Code inside the images by rebuilding them.
#
# Why a rebuild: Claude Code is installed from Anthropic's signed apt/dnf
# repository and DISABLE_AUTOUPDATER=1 is set, so the agent version is a
# property of the image tag, not of a running container. That is deliberate:
# the toolchain and the agent stay reproducible together.
#
# How the agent layer is actually replaced: the install step is a Docker layer
# like any other, so an unchanged Dockerfile plus unchanged build args is a
# cache hit and installs nothing. This script therefore resolves the version the
# channel offers right now and passes it as CLAUDE_VERSION, which changes the
# build arg and forces that layer to rebuild. Before 1.4.0 the only thing that
# busted it was the daily UPDATE_STAMP, so an upgrade with --no-updates, or a
# second upgrade on the same day, silently did nothing.
#
# Safety: the previous image is retagged :<tag>-prev before the rebuild, so a
# rollback is one `docker tag` away. Persistent state (OAuth token, sessions,
# ccache) lives on the host and is untouched.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

require_host

TARGETS=("${ALL_IMAGE_KEYS[@]}")
CLAUDE_VERSION=""
KEEP_CACHE=0
OS_UPDATES=1
OS_TAG=""
FROM_REGISTRY=0
TARGET_ARG=""

usage() {
    cat <<'USAGE'
usage: upgrade.sh [ubuntu|fedora|rocky|all] [options]
  -c, --claude-version VERSION  pin an exact Claude Code version instead of the
                                channel candidate
  -k, --keep-cache              keep the Docker layer cache for the OS packages.
                                Implies --no-updates: the OS layers can only be
                                reused if nothing before them changes. The agent
                                layer is still rebuilt.
      --from-registry           refresh from the published base instead of
                                rebuilding from source: re-pull, re-apply
                                updates, re-install the agents. Seconds.
      --no-updates              upgrade Claude Code only, leaving OS packages
                                exactly as the base image tag shipped them
  -t, --os-tag TAG              base image tag to build from

By default an upgrade also applies pending OS updates, because an image that
gets a new agent but keeps months-old system libraries is not really upgraded.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--claude-version) CLAUDE_VERSION="${2:?}"; shift 2 ;;
        --claude-version=*)  CLAUDE_VERSION="${1#*=}"; shift ;;
        -k|--keep-cache)     KEEP_CACHE=1; shift ;;
        --from-registry)     FROM_REGISTRY=1; shift ;;
        --no-updates)        OS_UPDATES=0; shift ;;
        -t|--os-tag)         OS_TAG="${2:?}"; shift 2 ;;
        --os-tag=*)          OS_TAG="${1#*=}"; shift ;;
        -h|--help)           usage; exit 0 ;;
        ubuntu|fedora|rocky|all) TARGET_ARG="$1"; shift ;;
        -*)                  die "unknown option: $1 (try --help)" ;;
        *)                   die "unexpected argument: $1" ;;
    esac
done

case "${TARGET_ARG:-all}" in
    all) TARGETS=("${ALL_IMAGE_KEYS[@]}") ;;
    ubuntu) TARGETS=(ubuntu) ;;
    fedora) TARGETS=(fedora) ;;
    rocky)  TARGETS=(rocky) ;;
esac

# Reusing the OS layers is only possible if nothing earlier in the Dockerfile
# changes, and OS updates deliberately change the first one every day. Say so
# rather than accepting a flag that quietly does nothing.
if (( KEEP_CACHE && OS_UPDATES )); then
    warn "-k/--keep-cache implies --no-updates; OS packages will stay as the base tag shipped them"
    OS_UPDATES=0
fi

require_engine

for key in "${TARGETS[@]}"; do
    ref="$(image_ref "$key")"
    before="-"
    want="$CLAUDE_VERSION"
    force_rebuild=0

    if image_exists "$ref"; then
        before="$(installed_claude_version "$ref")"
        "$ENGINE" tag "$ref" "${ref}-prev"
        log "$ref: Claude Code $before  ->  rollback tag ${ref}-prev created"

        if [[ -z "$want" ]]; then
            log "$ref: asking the ${key} channel what it offers"
            want="$(channel_candidate "$key" "$ref" || printf '')"
            if [[ -n "$want" ]]; then
                log "$ref: channel candidate $want"
            else
                warn "$ref: could not query the channel; rebuilding the agent layer without a pin"
                force_rebuild=1
            fi
        fi
    else
        log "$ref: not built yet, doing a first build"
    fi

    build_opts=(-C stable)
    if (( FROM_REGISTRY )); then
        # A derived image keeps the agents it was built with; pass them through
        # so a refresh does not silently drop them.
        build_opts+=(--from-registry)
        agents="$("$ENGINE" image inspect "$ref" \
                  --format '{{index .Config.Labels "com.ai-box.agents"}}' 2>/dev/null || true)"
        if [[ -n "$agents" && "$agents" != "<no value>" ]]; then
            build_opts+=(--agents "$agents")
            log "$ref was derived with agents: $agents"
        fi
    fi
    if [[ -n "$want" ]]; then
        build_opts+=(-c "$want")
    fi
    if [[ -n "$OS_TAG" ]]; then
        build_opts+=(--os-tag "$OS_TAG")
    fi
    if (( ! OS_UPDATES )); then
        build_opts+=(--no-updates)
    fi
    if (( force_rebuild )); then
        build_opts+=(--no-cache)
    fi

    "$PKG_ROOT/scripts/build.sh" "${build_opts[@]}" "$key"

    after="$(installed_claude_version "$ref")"
    if [[ "$before" == "$after" ]]; then
        warn "$ref: still Claude Code $after (channel had nothing newer)"
    else
        log "$ref: Claude Code $before -> $after"
    fi
done

cat <<'EOF'

Rollback if the new version misbehaves:
    "$ENGINE" tag ai-ubuntu:26.04-prev ai-ubuntu:26.04
    "$ENGINE" tag ai-fedora:44-prev    ai-fedora:44

Your credentials, sessions and ccache are on the host (~/.local/share/ai-box
and ~/.aikeys) and were not touched by this upgrade.

What changed in the image: the Claude Code version, and, unless you passed
--no-updates or --keep-cache, every OS package with a pending update.
`docker inspect` reports which: com.ai-box.os-updates and
com.ai-box.update-stamp.
EOF
