#!/usr/bin/env bash
# Keep the version in the documentation equal to the VERSION file.
#
#   stamp-version.sh           rewrite the stamped places to match VERSION
#   stamp-version.sh --check   report drift and exit non-zero (used by pack.sh)
#
# This exists because the version was stamped by hand and drifted: releases up to
# 2.0.3 shipped a README saying "Version: 1.6.2" and a quick start telling the
# reader to extract a tarball by a name that no longer existed. Each release had
# edited the string by search-and-replace on the *previous* version, and when the
# assumed previous value was wrong the replacement silently did nothing.
#
# Only a small set of patterns is stamped, and everything else is left alone.
# Prose like "since 1.6.2 the caches live in the workspace" is history and must
# not be rewritten -- which is exactly why a blanket version substitution across
# the docs would be wrong.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

CHECK=0
case "${1:-}" in
    --check) CHECK=1 ;;
    -h|--help) echo "usage: stamp-version.sh [--check]"; exit 0 ;;
    "") ;;
    *) die "unknown option: $1" ;;
esac

V="$PKG_VERSION"
SEMVER='[0-9]+\.[0-9]+\.[0-9]+'

# Documents that carry the current version. The changelog is excluded: it is a
# historical record and its version references are correct as written.
STAMPED_DOCS=(README.md AGENTS.md CLAUDE.md CONTRIBUTING.md SECURITY.md docs/*.md)

# Anchored rules, for the places where the version appears without the package
# name around it.
RULES=(
  "README.md|(\*\*Version:\*\* )${SEMVER}|\\1${V}"
  "README.md|(git tag v)${SEMVER}( && git push origin v)${SEMVER}|\\1${V}\\2${V}"
  "docs/operating-guide.md|(\*\*Package:\*\* ai-box v)${SEMVER}|\\1${V}"
  "docs/upgrading.md|(\*\*Applies to:\*\* ai-box v)${SEMVER}|\\1${V}"
  "docs/credentials.md|(\*\*Applies to:\*\* ai-box v)${SEMVER}|\\1${V}"
)

# Every `ai-box-v<semver>` in the documents above, wherever it appears.
#
# This used to be two anchored rules matching `tar xzf ai-box-v…` and
# `cd ai-box-v…`. Anything phrased differently was silently missed: a line
# reading `tar xzf ~/Downloads/ai-box-v2.3.1.tar.gz` did not match while the
# `cd` two lines below it did, so the README told a reader to extract one
# version and enter another. The operating guide still said 1.6.1, eleven
# releases later. A general rule cannot drift the way a list of phrasings does.
#
# To pin a specific version deliberately, put `stamp:keep` in a comment on that
# line and it will be left alone. `ai-box-vOLD` and `ai-box-vNEW` are already
# immune, since they are not version numbers.
stamp_paths() {   # stamp_paths <check?>
    local check="$1" f before line n=0
    for f in "${STAMPED_DOCS[@]}"; do
        [[ -f "$PKG_ROOT/$f" ]] || continue
        before="$(grep -nE "ai-box-v${SEMVER}" "$PKG_ROOT/$f" | grep -v 'stamp:keep' \
                  | grep -vF "ai-box-v${V}" || true)"
        [[ -n "$before" ]] || continue
        n=$((n + 1))
        if (( check )); then
            while IFS= read -r line; do
                printf '  %s: %s\n' "$f" "$(printf '%s' "$line" | cut -c1-92)"
            done <<< "$before"
        else
            # Rewrite every occurrence on lines not marked stamp:keep.
            perl -i -pe "s/ai-box-v${SEMVER}/ai-box-v${V}/g unless /stamp:keep/" "$PKG_ROOT/$f"
            printf '  stamped paths in %s\n' "$f"
        fi
    done
    return "$n"
}

drift=0
for rule in "${RULES[@]}"; do
    file="${rule%%|*}"; rest="${rule#*|}"
    pattern="${rest%%|*}"; repl="${rest#*|}"
    if [[ ! -f "$PKG_ROOT/$file" ]]; then
        # A rule naming a file that does not exist used to be skipped in silence,
        # so a renamed document quietly stopped being stamped. Say so.
        printf '  rule names a missing file: %s\n' "$file" >&2
        drift=$((drift + 1))
        continue
    fi

    before="$(grep -cE "$pattern" "$PKG_ROOT/$file" || true)"
    if (( ! before )); then
        # A rule that matches nothing is dead. Three of these went unnoticed
        # because flattening the documentation deleted the headers they matched,
        # so the check passed while three documents went unstamped for releases.
        # Missing-file was already reported; matching-nothing was not.
        printf '  rule matches nothing in %s: %s\n' "$file" "$pattern" >&2
        drift=$((drift + 1))
        continue
    fi

    stale="$(grep -E "$pattern" "$PKG_ROOT/$file" | grep -vF "$V" || true)"
    [[ -n "$stale" ]] || continue

    drift=$((drift + 1))
    if (( CHECK )); then
        printf '  %s: %s\n' "$file" "$(printf '%s' "$stale" | head -1 | cut -c1-90)"
    else
        sed -i -E "s|$pattern|$repl|g" "$PKG_ROOT/$file"
        printf '  stamped %s\n' "$file"
    fi
done

stamp_paths "$CHECK" || drift=$((drift + $?))

if (( CHECK )); then
    if (( drift )); then
        die "$drift file(s) disagree with VERSION ($V). Run scripts/stamp-version.sh"
    fi
    log "documentation version stamps match VERSION ($V)"
else
    (( drift )) && log "stamped $drift file(s) to $V" || log "already at $V"
fi
