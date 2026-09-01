#!/usr/bin/env bash
# Run locally what CI runs, from one definition.
#
# This exists because the list of checks used to live only in
# .github/workflows/ci.yml, so "run the same thing locally" meant copying
# commands out of a YAML file by hand. That is the duplication this project keeps
# being bitten by: two copies of one list, drifting quietly. The workflow now
# calls this script, so there is one definition and the local run is the CI run.
#
#   ci-local.sh                 the fast checks: lint, tests, gates, archive
#   ci-local.sh --with-images   also build every image and check it (slow, ~35 min)
#   ci-local.sh --pack-to DIR   write the archive where the caller wants it
#
# Run it as an ordinary user. CI runs unprivileged, and running as root hides
# failures: a test that creates a directory under /home passes as root and fails
# on a runner, which is exactly how one shipped broken.
set -uo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

WITH_IMAGES=0
PACK_TO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-images) WITH_IMAGES=1; shift ;;
        --pack-to)     PACK_TO="${2:?--pack-to needs a directory}"; shift 2 ;;
        --pack-to=*)   PACK_TO="${1#*=}"; shift ;;
        -h|--help)     sed -n '2,16p' "$(readlink -f "$0")" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "unknown option: $1" ;;
    esac
done

cd "$PKG_ROOT" || die "cannot enter $PKG_ROOT"

rc=0
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
bad()  { printf '\033[31mFAILED: %s\033[0m\n' "$1"; rc=1; }

if [[ "$(id -u)" == 0 ]]; then
    warn "running as root. CI runs unprivileged, and root hides failures such as"
    warn "a test able to create directories a normal user cannot."
fi

step "bash -n"
for f in scripts/* shared/*.sh tests/*.sh; do
    case "$f" in *.json|*.example|*.yaml) continue;; esac
    bash -n "$f" || bad "bash -n $f"
done
echo "ok"

step "shellcheck"
# Every ai-box image ships shellcheck, so a host without it can borrow one rather
# than being told to install a tool the product already contains. Note the
# wording: a comment line starting with the tool's name is read as a directive by
# the tool itself, which is its own small trap.
if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck disable=SC2046  # deliberate word splitting of the file list
    shellcheck -x -S warning $(find scripts shared tests -name '*.sh') \
        scripts/ai-box scripts/ai-keys && echo "ok" || bad shellcheck
elif command -v "$ENGINE" >/dev/null 2>&1 && image_exists "$(image_ref "$DEFAULT_IMAGE_KEY")"; then
    img="$(image_ref "$DEFAULT_IMAGE_KEY")"
    log "shellcheck not on this host; running it inside $img"
    if "$ENGINE" run --rm --user "$(id -u):$(id -g)" \
            --volume "$PKG_ROOT:/src$(selinux_relabel_opt)" --workdir /src \
            --entrypoint bash "$img" -lc \
            'shellcheck -x -S warning $(find scripts shared tests -name "*.sh") scripts/ai-box scripts/ai-keys'; then
        echo "ok (in container)"
    else
        bad shellcheck
    fi
else
    warn "shellcheck is not installed and no ai-box image is available to borrow one from."
    warn "Install it, or build an image first:  scripts/build.sh ${DEFAULT_IMAGE_KEY}"
    warn "CI gates on this check, so it is reported as a failure here too."
    bad "shellcheck missing"
fi

step "unit tests";          tests/run.sh                            || bad "unit tests"
step "image contract";      scripts/check-image-parity.sh           || bad parity
step "documentation links"; scripts/check-doc-links.sh              || bad doc-links
step "file inventory";      scripts/check-file-inventory.sh --strict || bad inventory
step "version stamps";      scripts/stamp-version.sh --check        || bad stamps

step "no credentials committed"
# Every vendor prefix the key parser recognises; keep in step with
# aibox_key_kind_of_value in shared/keyfile-lib.sh.
pat='sk-ant-(api|oat)[0-9]{2}-[A-Za-z0-9_-]{20,}'
pat="$pat"'|xai-[A-Za-z0-9]{24,}'
pat="$pat"'|sk-(proj|svcacct)-[A-Za-z0-9_-]{20,}'
pat="$pat"'|AIza[A-Za-z0-9_-]{30,}'
if grep -rInE "$pat" . --exclude-dir=.git; then
    bad "a credential-looking string is committed"
else
    echo "ok"
fi

step "build flags validate without an engine"
# Argument validation happens before the engine is touched, so a typo fails in
# seconds rather than after a long build.
! scripts/build.sh --lang bogus fedora      >/dev/null 2>&1 || bad "--lang not validated"
! scripts/build.sh --agents bogus fedora    >/dev/null 2>&1 || bad "--agents not validated"
! scripts/build.sh --toolchain silly fedora >/dev/null 2>&1 || bad "--toolchain not validated"
scripts/ai-box --version >/dev/null || bad "ai-box --version"
scripts/ai-box --help    >/dev/null || bad "ai-box --help"
echo "ok"

step "changelog has an entry for VERSION"
if grep -q "^## ${PKG_VERSION} " CHANGELOG.md; then echo "ok"; else bad "no changelog entry for ${PKG_VERSION}"; fi

step "archive invariants"
outdir="${PACK_TO:-$(mktemp -d)}"
mkdir -p "$outdir"
if scripts/pack.sh --stage "$outdir" >/dev/null; then
    archive="$outdir/ai-box-v${PKG_VERSION}.tar.gz"
    tops="$(tar tzf "$archive" | cut -d/ -f1 | sort -u)"
    if [[ "$tops" == "ai-box-v${PKG_VERSION}" ]]; then
        echo "one top-level directory: $tops"
    else
        bad "archive has unexpected top-level entries: $tops"
    fi
    if tar tzf "$archive" | grep -q '\.github'; then
        bad ".github leaked into the archive"
    else
        echo ".github excluded"
    fi
else
    bad pack
fi
[[ -n "$PACK_TO" ]] || rm -rf "$outdir"

if (( WITH_IMAGES )); then
    step "images (this is the slow half)"
    require_engine
    for key in "${ALL_IMAGE_KEYS[@]}"; do
        scripts/build.sh "$key"            || { bad "build $key"; continue; }
        scripts/verify-isolation.sh "$key" || bad "verify-isolation $key"
        scripts/smoke-test.sh "$key"       || bad "smoke-test $key"
    done
    scripts/capabilities.sh || bad capabilities
else
    printf '\n'
    log "image checks skipped. They are the half that source checks cannot cover:"
    log "  scripts/ci-local.sh --with-images     (about 35 minutes)"
fi

printf '\n'
if (( rc == 0 )); then
    printf '\033[32mall checks passed\033[0m\n'
else
    printf '\033[31msome checks failed\033[0m\n'
fi
exit $rc
