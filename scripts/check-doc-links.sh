#!/usr/bin/env bash
# Every docs/… path mentioned anywhere in the package must exist.
#
# `check-file-inventory.sh` compares the tree against the README's table, which
# catches a file with no row. It does not catch the opposite: a *reference* to a
# document that is not there. Renaming the documentation for publication left six
# such references behind, in scripts rather than in markdown, two of which are
# printed to the user at runtime -- the container banner and an ai-box error
# message both told people to read a file that no longer existed.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

cd "$PKG_ROOT"

missing=0
checked=0
while IFS= read -r ref; do
    checked=$((checked + 1))
    [[ -f "$ref" ]] && continue
    printf '  \033[31mmissing\033[0m %s\n' "$ref"
    grep -rIn --exclude-dir=.git --exclude=CHANGELOG.md -- "$ref" . \
        | sed 's/^/      referenced by /' | head -5
    missing=$((missing + 1))
done < <(
    # Any docs/<name>.md that appears in any file, minus the changelog, which is
    # a historical record and legitimately names files that have since moved.
    grep -rIoh --exclude-dir=.git --exclude=CHANGELOG.md -E 'docs/[A-Za-z0-9._-]+\.md' . \
        | sort -u
)

if (( missing )); then
    die "$missing referenced document(s) do not exist. Fix the reference or restore the file."
fi
# README.md, AGENTS.md and CLAUDE.md must agree about what each other is for.
# They have drifted before: the README said "two images" while listing three, and
# CLAUDE.md described a two-image package after the third had shipped.
sync_problems=()
grep -q 'AGENTS.md' CLAUDE.md          || sync_problems+=("CLAUDE.md does not point at AGENTS.md")
grep -q 'README.md' CLAUDE.md          || sync_problems+=("CLAUDE.md does not point at README.md")
grep -q 'README.md' AGENTS.md          || sync_problems+=("AGENTS.md does not point at README.md")
grep -q 'AGENTS.md' README.md          || sync_problems+=("README.md does not mention AGENTS.md")

# The image count is the specific thing that drifted, so check it explicitly.
# The number of images is read from the README's own table, so the check has no
# hardcoded count to go stale in its turn.
n_images="$(grep -cE '^\| `ai-(ubuntu|fedora|rocky)' README.md || true)"
[[ -n "$n_images" ]] || n_images=3
# Every document, not only the top four: seven of the eleven stale
# "both images" phrases were in docs/.
while IFS= read -r f; do
    # "two", "both" and "either" all assume a two-image package. The first
    # version of this check looked only for "two images" and missed ten
    # occurrences of the other two words.
    # Anchored on phrasings that mean "the package has two images", not on any
    # sentence containing the word two: "one major behind the other two images"
    # and "two images will fight over one build tree" are both correct prose.
    if hit="$(grep -niE '\b(both (docker )?(images|dockerfiles))|((builds?|contains?|ships?) two (docker )?images)|(in either image)\b' "$f" | head -1)"; then
        [[ -n "$hit" ]] && sync_problems+=("$f assumes a two-image package (there are ${n_images}): ${hit}")
    fi
done < <(find . -name '*.md' -not -name CHANGELOG.md -not -path './.git/*' | sort)

if (( ${#sync_problems[@]} )); then
    printf '  %s\n' "${sync_problems[@]}" >&2
    die "README.md, AGENTS.md and CLAUDE.md disagree"
fi

log "all $checked referenced documents exist; README/AGENTS/CLAUDE agree"
