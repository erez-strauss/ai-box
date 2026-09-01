#!/usr/bin/env bash
# Assert that README.md's file inventory matches the files that actually exist.
#
# The inventory exists because "what is this file for?" is a real question about
# a package whose whole value is that you can audit it. A table nobody updates
# answers it wrongly, which is worse than not answering it, so this check makes
# forgetting a build failure rather than a slow decay.
#
# The two directions are deliberately not symmetric:
#
#   * a file present in the tree but absent from the table is a FAILURE. That is
#     the case this check exists for: something was added and not documented.
#   * a table row with no file behind it is a WARNING by default, because the
#     release tarball legitimately omits the .github/ group, so an extracted
#     tarball would fail on rows that are correct in the repository. Pass
#     --strict, as CI does from a full checkout, to make it fatal there too.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

STRICT=0
case "${1:-}" in
    --strict) STRICT=1 ;;
    -h|--help) echo "usage: check-file-inventory.sh [--strict]"; exit 0 ;;
    "") ;;
    *) die "unknown option: $1" ;;
esac

README="$PKG_ROOT/README.md"
[[ -r "$README" ]] || die "no README.md at $PKG_ROOT"

BEGIN='<!-- BEGIN FILE INVENTORY -->'
END='<!-- END FILE INVENTORY -->'
grep -qF "$BEGIN" "$README" || die "README.md has no $BEGIN marker"
grep -qF "$END"   "$README" || die "README.md has no $END marker"

# Documented: the first backticked path in each table row between the markers.
# Group headings are bold paragraphs, not table rows, so they never match.
documented="$(mktemp)"
listed="$(mktemp)"
trap 'rm -f "$documented" "$listed"' EXIT

awk -v b="$BEGIN" -v e="$END" '
    index($0, b) { inside = 1; next }
    index($0, e) { inside = 0 }
    inside && /^\| *`[^`]+` *\|/ {
        line = $0
        sub(/^\| *`/, "", line)
        sub(/`.*$/, "", line)
        print line
    }
' "$README" | sort -u > "$documented"

[[ -s "$documented" ]] || die "no file rows found between the inventory markers"

# Actual: every file in the tree, minus things that are not package content.
# .git is not content; a built archive is an output, not an input.
# Running ai-box against this checkout leaves these here: decision D1 puts caches
# in the project. pack.sh already knows they are not content; this check did not,
# so using the product on its own tree failed a CI-gated check.
#
# This list and the function below went missing between 2.2.0 and 2.3.3: the edit
# that added them anchored on a line that exists in check-doc-links.sh and not in
# this file, so the function was never defined while the call to it remained. The
# result exited 0 while printing "is_not_package: command not found" for every
# file, and the redirection in the release gates hid it.
NOT_PACKAGE=(
    '.cache-*' '.ccache-*' 'core.*' '.claude' '.claude.json'
    '*-review*.md' '*-workplan*.md' '.git'
)
is_not_package() {
    local p="$1" pat
    for pat in "${NOT_PACKAGE[@]}"; do
        # shellcheck disable=SC2053  # glob match is intended
        [[ "$p" == $pat || "$p" == $pat/* || "$(basename "$p")" == $pat ]] && return 0
    done
    return 1
}

find "$PKG_ROOT" -type f \
    -not -path "$PKG_ROOT/.git/*" \
    -not -name '*.tar.gz' \
    -not -name 'SHA256SUMS' \
    | sed "s|^$PKG_ROOT/||" | sort -u > "$listed.all"

: > "$listed"
while IFS= read -r rel; do
    is_not_package "$rel" || printf '%s\n' "$rel" >> "$listed"
done < "$listed.all"
sort -u -o "$listed" "$listed"

# A file list that came out empty means the enumeration failed, not that the
# package is empty. Without this the check reported success while doing nothing.
[[ -s "$listed" ]] || die "file enumeration produced nothing; the check is broken, not the tree"

undocumented="$(comm -13 "$documented" "$listed")"
missing="$(comm -23 "$documented" "$listed")"

rc=0
if [[ -n "$undocumented" ]]; then
    printf 'files present but not in the README inventory:\n' >&2
    printf '  %s\n' $undocumented >&2
    rc=1
fi

if [[ -n "$missing" ]]; then
    if (( STRICT )); then
        printf 'README inventory lists files that do not exist:\n' >&2
        printf '  %s\n' $missing >&2
        rc=1
    else
        printf 'note: inventory lists files not present here (expected from an\n' >&2
        printf '      extracted tarball, which omits .github/):\n' >&2
        printf '  %s\n' $missing >&2
    fi
fi

if (( rc == 0 )); then
    log "README inventory matches the tree ($(wc -l < "$listed") files)"
else
    die "README inventory is out of date; add or remove rows in the section between the markers"
fi
