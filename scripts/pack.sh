#!/usr/bin/env bash
# Rebuild the distribution tarball from this working tree.
#
# Guarantees: the archive is named ai-box-v<VERSION>.tar.gz and every
# member lives under a top-level directory of the same name, so extracting two
# different versions side by side can never overwrite each other's files. The
# finished archive is checked against that invariant rather than trusted.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

STAGE=0
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--stage) STAGE=1; shift ;;
        -h|--help)
            cat <<'USAGE'
usage: pack.sh [-s|--stage] [OUT_DIR]
  -s  copy the package into a correctly named directory before packing. Needed
      from a git checkout, where the working directory is named after the
      repository rather than after the version. Strict is still the default: a
      release cut from an unpacked tarball should keep failing loudly if the
      directory name and VERSION have drifted apart.
USAGE
            exit 0 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

NAME="ai-box-v${PKG_VERSION}"
OUT_DIR="${1:-$(dirname "$PKG_ROOT")}"
OUT="${OUT_DIR}/${NAME}.tar.gz"

# The version in the documentation must equal the VERSION file. Releases up to
# 2.0.3 shipped a README claiming 1.6.2 and a quick start naming a tarball that
# did not exist, because the stamp was maintained by hand and nothing checked it.
"$PKG_ROOT/scripts/stamp-version.sh" --check

# A reference to a document that is not in the archive is a broken link for
# every reader of the release, so it blocks the release.
"$PKG_ROOT/scripts/check-doc-links.sh"

need tar

# Ship exactly the package, and nothing else that happens to be in the working
# tree. This is an allowlist rather than a blocklist on purpose: a blocklist
# ships every stray file nobody thought to name, and two of them have already
# made it into an archive (a machine-local .claude/settings.local.json, and a
# session note dropped in the package root).
#
# .github/ is deliberately not a member. It is repository infrastructure that
# only means anything on GitHub; shipping it in a tarball would suggest the
# workflows run for whoever extracts it.
MEMBERS=(
    README.md CHANGELOG.md AGENTS.md CLAUDE.md CONTRIBUTING.md SECURITY.md LICENSE
    VERSION .dockerignore
    docker-ubuntu docker-fedora docker-rocky docker-derive shared scripts docs tests
)

# Top-level entries that are intentionally not shipped. Anything present in the
# tree but in neither list stops the build. The previous version only warned,
# and 1.7.0 duly shipped without docker-rocky/ -- a whole image silently absent
# from the release, because a warning in a long build log is not a check.
NOT_SHIPPED=(
    .git .github .gitignore .hadolint.yaml
    .claude .claude.json          # a maintainer's own session state, never shipped
    # Running ai-box with this directory as the project leaves these behind
    # (decision D1: caches live in the workspace). They must not be able to
    # block a release, and they are not package content.
    .cache-ubuntu .cache-fedora .cache-rocky
    .ccache-ubuntu .ccache-fedora .ccache-rocky
)

missing=()
for m in "${MEMBERS[@]}"; do
    if [[ ! -e "$PKG_ROOT/$m" ]]; then missing+=("$m"); fi
done
if (( ${#missing[@]} )); then
    die "missing from the package: ${missing[*]}"
fi

# Say what is being left behind, so an omission is never silent.
skipped=()
for entry in "$PKG_ROOT"/* "$PKG_ROOT"/.[!.]*; do
    [[ -e "$entry" ]] || continue
    base="$(basename "$entry")"
    case " ${MEMBERS[*]} " in
        *" $base "*) ;;
        *) skipped+=("$base") ;;
    esac
done
unexpected=()
for base in "${skipped[@]+"${skipped[@]}"}"; do
    case "$base" in
        core.*) continue ;;   # a crashed process left this; never package content
    esac
    case " ${NOT_SHIPPED[*]} " in
        *" $base "*) ;;
        *) unexpected+=("$base") ;;
    esac
done
if (( ${#skipped[@]} )); then
    log "not shipped (by design): ${skipped[*]}"
fi
if (( ${#unexpected[@]} )); then
    die "these exist in the tree but are in neither MEMBERS nor NOT_SHIPPED: ${unexpected[*]}
       Add each to one list. A release that silently omits a directory is how
       1.7.0 shipped without its Rocky image."
fi

# Where tar reads the members from. Normally the package's own parent, because
# the directory is already named for the version; with --stage, a temporary
# copy under the right name.
SRC_PARENT="$(dirname "$PKG_ROOT")"
if [[ "$(basename "$PKG_ROOT")" != "$NAME" ]]; then
    if (( STAGE )); then
        STAGE_DIR="$(mktemp -d)"
        trap 'rm -rf "$STAGE_DIR"' EXIT
        mkdir -p "$STAGE_DIR/$NAME"
        tar --create --exclude-vcs --directory "$PKG_ROOT" -- "${MEMBERS[@]}" \
            | tar --extract --directory "$STAGE_DIR/$NAME"
        SRC_PARENT="$STAGE_DIR"
        log "staged $(basename "$PKG_ROOT") as $NAME"
    else
        die "package directory is $(basename "$PKG_ROOT") but VERSION says $PKG_VERSION.
       Rename it to $NAME, or pass --stage to copy it into a correctly named
       directory first (which is what a git checkout needs)."
    fi
fi

if [[ -e "$OUT" ]]; then
    die "$OUT already exists -- bump VERSION instead of overwriting a released archive"
fi
mkdir -p "$OUT_DIR"

tar --create --gzip \
    --owner=0 --group=0 --numeric-owner \
    --exclude-vcs \
    --directory "$SRC_PARENT" \
    --file "$OUT" "${MEMBERS[@]/#/$NAME/}"

# The invariant the whole versioning scheme rests on: exactly one top-level
# entry, named for the version, so two releases never overwrite each other.
# Asserted against the finished file, not assumed from how it was built.
tops="$(tar tzf "$OUT" | cut -d/ -f1 | sort -u)"
if [[ "$tops" != "$NAME" ]]; then
    rm -f "$OUT"
    die "archive would have contained more than one top-level entry: $tops"
fi

log "wrote $OUT"
tar --list --file "$OUT" | sed -n '1,200p'
