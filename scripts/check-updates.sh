#!/usr/bin/env bash
# Report, per image: the Claude Code version baked in vs. the candidate now
# offered by the signed apt/dnf channel, plus the upstream release for context.
# Read-only: uses throwaway containers, touches neither images nor state.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

require_host

require_engine

upstream="unknown"
if command -v curl >/dev/null 2>&1; then
    upstream="$(curl -fsSL --max-time 10 \
        https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)"
    [[ -n "$upstream" ]] || upstream="unknown"
fi

printf '%-24s %-18s %-18s %s\n' IMAGE INSTALLED CANDIDATE STATUS
for key in "${ALL_IMAGE_KEYS[@]}"; do
    ref="$(image_ref "$key")"
    if ! image_exists "$ref"; then
        printf '%-24s %-18s %-18s %s\n' "$ref" "-" "-" "not built"
        continue
    fi
    have="$(installed_claude_version "$ref")"
    want="$(channel_candidate "$key" "$ref" || printf '')"
    want="${want:-unknown}"
    # apt candidates may carry a packaging suffix (2.1.211-1); compare the head.
    if [[ "${want%%-*}" == "$have" ]]; then status="up to date"
    elif [[ "$want" == "unknown" ]]; then status="could not query repo"
    else status="UPGRADE AVAILABLE"; fi
    printf '%-24s %-18s %-18s %s\n' "$ref" "$have" "$want" "$status"
done

printf '\nUpstream latest release (npm dist-tag, for reference): %s\n' "$upstream"
printf 'To upgrade:  scripts/upgrade.sh          (both images, channel candidate)\n'
printf '             scripts/upgrade.sh -c X.Y.Z (pin an exact version)\n'
