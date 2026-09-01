#!/usr/bin/env bash
# What each built image actually contains, side by side.
#
# The images deliberately do not carry identical toolchains (decision D3a: newest
# available per image). That makes "which image has what" a real question, and
# guessing from the Dockerfiles is how people end up surprised. This reads
# /etc/toolchain-versions out of each built image, so it reports what shipped
# rather than what was intended.
#
#   capabilities.sh              table for every built image
#   capabilities.sh --markdown   the same, ready to paste into README.md
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

require_host

MD=0
[[ "${1:-}" == "--markdown" ]] && MD=1
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { echo "usage: capabilities.sh [--markdown]"; exit 0; }

require_engine

TOOLS=(gcc g++ clang clang++ cmake ninja ccache mold ld.lld gdb valgrind perf
       clang-tidy clang-format cppcheck iwyu lcov gcovr doxygen dot patchelf
       readelf objdump nm addr2line shellcheck
       python pip uv ruff mypy pytest node
       rustc cargo go javac ruby lua)

# Reported separately, because "which agents does this image have, and at what
# version" is the question people actually ask. claude is always present; the
# others appear only when the image was built with --agents.
AGENTS=(claude codex gemini grok)

declare -A have
present=()
for key in "${ALL_IMAGE_KEYS[@]}"; do
    ref="$(image_ref "$key")"
    image_exists "$ref" || continue
    present+=("$key")
    while IFS= read -r line; do
        tool="${line%% *}"; ver="${line#"$tool"}"
        have["$key/$tool"]="$(printf '%s' "$ver" | sed 's/^ *//')"
    done < <("$ENGINE" run --rm "$ref" cat /etc/toolchain-versions 2>/dev/null | tail -n +3)
done

(( ${#present[@]} )) || die "no images built yet; run scripts/build.sh all"

# Keep the version, drop the packaging noise around it.
short() { printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true; }

# Some tools have different binary names per distro. Report one row, filled by
# whichever name that image has: iwyu on Ubuntu is include-what-you-use on Fedora,
# and the table showed n/a for an installed tool because it only looked for one.
alias_of() {
    case "$1" in
        iwyu)   printf 'include-what-you-use' ;;
        fd)     printf 'fdfind' ;;
        *)      printf '' ;;
    esac
}

emit_rows() {   # emit_rows <markdown?> <tool>...
    local md="$1"; shift
    local t k v row any cell
    for t in "$@"; do
        row=""; any=0
        for k in "${present[@]}"; do
            v="$(short "${have["$k/$t"]:-}")"
            if [[ -z "$v" ]]; then
                alt="$(alias_of "$t")"
                [[ -n "$alt" ]] && v="$(short "${have["$k/$alt"]:-}")"
            fi
            [[ -n "$v" ]] && any=1
            if (( md )); then
                row+=" ${v:-n/a} |"
            else
                printf -v cell '%-14s' "${v:-n/a}"; row+="$cell"
            fi
        done
        (( any )) || continue
        if (( md )); then printf '| `%s` |%s\n' "$t" "$row"
        else printf '%-10s%s\n' "$t" "$row"; fi
    done
}

if (( MD )); then
    printf '| Tool |'; for k in "${present[@]}"; do printf ' %s |' "$k"; done; printf '\n|---|'
    for _ in "${present[@]}"; do printf '%s' '---|'; done; printf '\n'
    emit_rows 1 "${TOOLS[@]}"
    printf '\n**AI agents**\n\n'
    printf '| Agent |'; for k in "${present[@]}"; do printf ' %s |' "$k"; done; printf '\n|---|'
    for _ in "${present[@]}"; do printf '%s' '---|'; done; printf '\n'
    emit_rows 1 "${AGENTS[@]}"
else
    printf '%-10s' 'TOOL'; for k in "${present[@]}"; do printf '%-14s' "$k"; done; printf '\n'
    emit_rows 0 "${TOOLS[@]}"
    printf '\n%-10s' 'AGENT'; for k in "${present[@]}"; do printf '%-14s' "$k"; done; printf '\n'
    emit_rows 0 "${AGENTS[@]}"
    printf '\n"n/a" means the tool is absent from that image. Tool versions differ by\n'
    printf 'design (decision D3a: newest obtainable per image). Agents other than\n'
    printf 'claude appear only when the image was built with --agents.\n'
fi
