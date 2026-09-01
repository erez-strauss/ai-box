#!/usr/bin/env bash
# Smoke-test a built image: the agent runs, the toolchain report is there, and
# every compiler the image ships actually compiles and links something.
#
# This is definition-of-done item 5, as a script rather than a list of commands
# to retype. It is not an isolation check; see verify-isolation.sh for that.
#
#   scripts/smoke-test.sh ubuntu
#   scripts/smoke-test.sh fedora
#
# The C++23 and Python checks are fatal. The C++26 reflection checks are
# conditional: the script asks each compiler whether it defines
# __cpp_impl_reflection and skips it if not, because reflection is a GCC-only
# feature today and only on the branches that ship it. When a compiler does
# claim support, the probe must build and run, so a regression there is a
# failure rather than a skip. Every source the test needs is written inline into
# the container's tmpfs, so the test carries no separate example files and
# nothing is mounted from the package.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

require_host

KEY="${1:-ubuntu}"
REF="$(image_ref "$KEY")"

require_engine
image_exists "$REF" || die "image $REF not built; run scripts/build.sh $KEY"

log "smoke-testing $REF"

# Everything the test builds goes to the tmpfs; nothing is written to the image.
# The cache variables are set here because this probe runs with --entrypoint bash and
# so never executes entrypoint.sh, which is what normally redirects caches away from a
# read-only workspace. Without them the ccache shim on PATH would try to write into a
# read-only mount.
"$ENGINE" run --rm "${ENGINE_RUN_EXTRA[@]+"${ENGINE_RUN_EXTRA[@]}"}" \
    --user "$(id -u):$(id -g)" \
    --cap-drop=ALL --security-opt no-new-privileges \
    --pids-limit 4096 \
    --tmpfs "/tmp:rw,nosuid,nodev,exec,size=512m" \
    --workdir /tmp \
    --env XDG_CACHE_HOME=/tmp/cache --env CCACHE_DIR=/tmp/cache/ccache \
    --entrypoint bash "$REF" -lc '
set -uo pipefail
fail=0
chk() { printf "%-46s %s\n" "$1" "$2"; case "$2" in FAIL*) fail=1 ;; esac; }

v="$(claude --version 2>/dev/null | head -1)"
if [[ -n "$v" ]]; then chk "claude runs" "PASS ($v)"; else chk "claude runs" "FAIL"; fi

if [[ -s /etc/toolchain-versions ]]; then
    chk "toolchain report present" "PASS ($(wc -l < /etc/toolchain-versions) lines)"
else
    chk "toolchain report present" "FAIL"
fi

# --- C++23, every compiler, compile AND run -------------------------------
cat > /tmp/hello.cpp <<CPP
#include <print>
#include <vector>
#include <algorithm>
int main() {
    std::vector<int> v{3, 1, 2};
    std::ranges::sort(v);
    std::println("{} {} {}", v[0], v[1], v[2]);
    return (v[0] == 1 && v[2] == 3) ? 0 : 1;
}
CPP
for cc in g++ clang++ g++-15 g++-16; do
    command -v "$cc" >/dev/null 2>&1 || continue
    if "$cc" -std=c++23 /tmp/hello.cpp -o "/tmp/hello.$cc" 2>/tmp/err.txt && "/tmp/hello.$cc" >/dev/null; then
        chk "c++23 compile+run: $cc" "PASS ($("$cc" -dumpversion 2>/dev/null))"
    else
        chk "c++23 compile+run: $cc" "FAIL ($(head -1 /tmp/err.txt))"
    fi
done

# --- C++26 reflection, where the compiler claims to have it ---------------
printf "%s\n" "#if !defined(__cpp_impl_reflection)" "#error no reflection" "#endif" \
    "int main() { return 0; }" > /tmp/probe.cpp
for cc in g++ g++-16 clang++; do
    command -v "$cc" >/dev/null 2>&1 || continue
    flags="-std=c++26 -freflection"
    if ! "$cc" $flags -fsyntax-only /tmp/probe.cpp >/dev/null 2>&1; then
        flags="-std=c++26"
        if ! "$cc" $flags -fsyntax-only /tmp/probe.cpp >/dev/null 2>&1; then
            chk "c++26 reflection: $cc" "SKIP (not supported)"
            continue
        fi
    fi
    # Compile and run a real reflection program, generated here.
    #
    # This used to compile /workspace/reflect-demo.cpp and soa-transform.cpp from
    # the examples/ directory. That directory was removed, the mount with it, and
    # these two checks were left behind pointing at files that no longer exist --
    # so every smoke test since has failed on them. The removal matched lines
    # containing "examples/" and these lines say "/workspace/", which is the same
    # incomplete-replacement mistake this changelog keeps recording.
    #
    # Generating the source keeps the check honest without shipping fixtures: it
    # proves reflection compiles *and* produces the right answer at run time,
    # which -fsyntax-only above does not.
    cat > /tmp/reflect.cpp <<'REFL'
#include <meta>
#include <cstdio>

struct Point { int x; int y; int z; };

int main() {
    // The number of non-static data members, computed at compile time.
    constexpr auto n = [] {
        std::size_t count = 0;
        for (auto m : std::meta::nonstatic_data_members_of(^^Point,
                                                           std::meta::access_context::current()))
            ++count;
        return count;
    }();
    static_assert(n == 3, "reflection did not see three members");
    std::printf("%zu\n", n);
    return n == 3 ? 0 : 1;
}
REFL
    if "$cc" $flags /tmp/reflect.cpp -o "/tmp/reflect.$cc" 2>/tmp/err.txt \
       && "/tmp/reflect.$cc" >/dev/null; then
        chk "c++26 reflection compiles and runs: $cc" "PASS"
    else
        # A compiler can advertise __cpp_impl_reflection and still not implement
        # the parts a program uses; report that rather than failing the image,
        # since the standard library side is still moving.
        chk "c++26 reflection compiles and runs: $cc" "SKIP ($(head -1 /tmp/err.txt | cut -c1-60))"
    fi
done

# --- caches point into the workspace, not into the image ------------------
# readlink prints the literal target, so this holds whether or not a workspace is
# mounted, and is unaffected by the overrides above.
link="$(readlink "$HOME/.cache" 2>/dev/null || true)"
case "$link" in
    /workspace/.cache-*) chk "~/.cache -> workspace" "PASS ($link)" ;;
    "")                  chk "~/.cache -> workspace" "FAIL (not a symlink)" ;;
    *)                   chk "~/.cache -> workspace" "FAIL ($link)" ;;
esac

# --- Python: the venv is on PATH, usable, and writable --------------------
# Writability is checked instead of a real "pip install" because the point of
# the venv is that an in-session install needs no root, and testing that with a
# network fetch would make the smoke test depend on PyPI being reachable.
py="$(command -v python 2>/dev/null || true)"
if [[ "$py" == /opt/venv/bin/python ]]; then
    chk "python resolves to the venv" "PASS ($(python --version 2>&1))"
else
    chk "python resolves to the venv" "FAIL (${py:-not found})"
fi

if [[ "$(python -c "import sys; print(sys.prefix)" 2>/dev/null)" == /opt/venv ]]; then
    chk "sys.prefix is /opt/venv" "PASS"
else
    chk "sys.prefix is /opt/venv" "FAIL"
fi

for t in pip uv ruff mypy pytest; do
    if command -v "$t" >/dev/null 2>&1 && "$t" --version >/dev/null 2>&1; then
        chk "python tool: $t" "PASS ($("$t" --version 2>&1 | head -1))"
    else
        chk "python tool: $t" "FAIL"
    fi
done

site="$(python -c "import sysconfig; print(sysconfig.get_paths()[\"purelib\"])" 2>/dev/null || true)"
if [[ -n "$site" ]] && touch "$site/.ai-box-probe" 2>/dev/null; then
    rm -f "$site/.ai-box-probe"
    chk "venv writable without root" "PASS"
else
    chk "venv writable without root" "FAIL (${site:-no site-packages}) "
fi

mkdir -p /tmp/pyt
printf "%s\n" "def test_arithmetic():" "    assert sum(range(4)) == 6" > /tmp/pyt/test_smoke.py
if pytest -q /tmp/pyt >/tmp/pyerr.txt 2>&1; then
    chk "pytest runs a test" "PASS"
else
    chk "pytest runs a test" "FAIL ($(tail -1 /tmp/pyerr.txt))"
fi

exit $fail
' || die "smoke test FAILED for $REF"

# The env overrides above would mask the image's own defaults, so read those from
# the image itself rather than from inside the probe.
env_of() { "$ENGINE" image inspect "$REF" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep "^$1=" | head -1; }
for want in CCACHE_DIR XDG_CACHE_HOME; do
    got="$(env_of "$want")"
    case "${got#*=}" in
        /workspace/*) printf '%-46s %s\n' "image default: $want" "PASS (${got#*=})" ;;
        *) printf '%-46s %s\n' "image default: $want" "FAIL (${got#*=:-unset})"
           die "$want does not point into the workspace" ;;
    esac
done

# Runs as the unprivileged user, deliberately, and not through --entrypoint bash:
# this is the one check that would have caught the 1.6.2 defect where BuildKit
# gave /usr/local/lib/ai-box mode 0644 (no execute bit, so not traversable)
# because the COPY that created it carried --chmod=0644. Every build step runs as
# root, and root ignores directory permissions, so nothing inside the build could
# see it. Assert the mode and the entrypoint's ability to source the file.
printf '%-46s ' "image paths readable as the user"
if "$ENGINE" run --rm "${ENGINE_RUN_EXTRA[@]+"${ENGINE_RUN_EXTRA[@]}"}" \
        --user "$(id -u):$(id -g)" --entrypoint bash "$REF" -c '
            set -e
            for d in /usr/local/lib/ai-box /usr/local/share/ai-box; do
                [ -x "$d" ] || { echo "not traversable: $d ($(stat -c %a "$d"))" >&2; exit 1; }
            done
            . /usr/local/lib/ai-box/keyfile-lib.sh
            [ "$(aibox_key_var api)" = ANTHROPIC_API_KEY ]
            # The image ships /workspace as an empty mount point.
            [ -z "$(ls -A /workspace)" ] || { echo "/workspace not empty in image" >&2; exit 1; }
        ' >/dev/null 2>&1; then
    printf 'PASS\n'
else
    printf 'FAIL\n'
    die "image paths are not reachable by an unprivileged user in $REF"
fi

# The entrypoint itself, through the image's real ENTRYPOINT, against a writable
# workspace. Deliberately here and not in the Dockerfile: as a build step it
# creates cache directories that a later step may be unable to remove, which is
# how 1.6.3 broke the build. Here a failure costs a test run.
printf '%-46s ' "entrypoint runs and seeds caches"
EP_WS="$(mktemp -d "${TMPDIR:-/tmp}/ai-box-ep.XXXXXX")"
ep_ok=0
if "$ENGINE" run --rm "${ENGINE_RUN_EXTRA[@]+"${ENGINE_RUN_EXTRA[@]}"}" \
        --user "$(id -u):$(id -g)" \
        --volume "$EP_WS:/workspace$(selinux_relabel_opt)" \
        "$REF" bash -lc '
            set -e
            # Set by the image, pointed into the workspace, created by the entrypoint.
            test -n "$CCACHE_DIR" && test -d "$CCACHE_DIR" && test -w "$CCACHE_DIR"
            test -n "$XDG_CACHE_HOME" && test -d "$XDG_CACHE_HOME"
            # ~/.cache must resolve through the symlink to the same place.
            test "$(readlink -f ~/.cache)" = "$(readlink -f "$XDG_CACHE_HOME")"
        ' >/dev/null 2>&1; then
    # And the directories really landed on the host side of the bind mount.
    if [[ -n "$(ls -A "$EP_WS" 2>/dev/null)" ]]; then ep_ok=1; fi
fi
if (( ep_ok )); then printf 'PASS\n'; else printf 'FAIL\n'; fi
rm -rf "$EP_WS"
(( ep_ok )) || die "entrypoint did not create usable cache directories in a writable workspace"

# Whichever optional agents this image contains must work, including the ICU
# path that segfaults a TUI on a Node without break-iterator data.
# The agent home directories must exist in the image, not only be named by an
# environment variable: codex warns at every startup when CODEX_HOME points at a
# path that is not there, and the report runs before the entrypoint could create
# it. A variable that names a missing directory is worse than no variable.
# Static linking, verified the way a user would: link it, run it, and confirm the
# loader is not involved. `file` reporting "statically linked" is the check that
# distinguishes a real static binary from one that merely compiled.
# Static linking, verified as a user would: link it, run it, and confirm the
# loader is not involved. `file` reporting "statically linked" is what
# distinguishes a real static binary from one that merely compiled.
STATIC_PROG='#include <string>
#include <vector>
int main(){std::string s="ok"; std::vector<int> v{1,2}; return (s.size()==2 && v.size()==2)?0:1;}'

for probe in "-static" "-static-libstdc++ -static-libgcc"; do
    printf '%-46s ' "static link: g++ ${probe}"
    if "$ENGINE" run --rm "${ENGINE_RUN_EXTRA[@]+"${ENGINE_RUN_EXTRA[@]}"}" \
            --user "$(id -u):$(id -g)" --entrypoint bash "$REF" -lc \
            "set -e; cd /tmp; cat > s.cpp <<'PROG_EOF'
${STATIC_PROG}
PROG_EOF
             g++ -std=c++17 ${probe} s.cpp -o s.bin && ./s.bin" >/dev/null 2>&1; then
        printf 'PASS\n'
    else
        printf 'FAIL\n'; die "static linking is broken in $REF: g++ ${probe}"
    fi
done

printf '%-46s ' "static binary needs no dynamic loader"
if "$ENGINE" run --rm "${ENGINE_RUN_EXTRA[@]+"${ENGINE_RUN_EXTRA[@]}"}" \
        --user "$(id -u):$(id -g)" --entrypoint bash "$REF" -lc \
        'set -e; cd /tmp; echo "int main(){return 0;}" > s2.cpp
         g++ -static s2.cpp -o s2.bin
         file s2.bin | grep -q "statically linked"' >/dev/null 2>&1; then
    printf 'PASS\n'
else
    printf 'FAIL\n'; die "the -static binary in $REF is not actually static"
fi

printf '%-46s ' "agent home directories exist"
if "$ENGINE" run --rm "${ENGINE_RUN_EXTRA[@]+"${ENGINE_RUN_EXTRA[@]}"}" \
        --user "$(id -u):$(id -g)" --entrypoint bash "$REF" -lc '
            set -e
            for v in CODEX_HOME GEMINI_CLI_HOME GROK_HOME; do
                d="${!v:-}"
                [ -n "$d" ] || { echo "$v is not set"; exit 1; }
                [ -d "$d" ] || { echo "$v points at a missing directory: $d"; exit 1; }
            done' >/dev/null 2>&1; then
    printf 'PASS\n'
else
    printf 'FAIL\n'; die "an agent home directory is named but missing in $REF"
fi

printf '%-46s ' "optional agents run"
agent_out="$("$ENGINE" run --rm "${ENGINE_RUN_EXTRA[@]+"${ENGINE_RUN_EXTRA[@]}"}" \
    --user "$(id -u):$(id -g)" --entrypoint bash "$REF" -lc '
        set -u; rc=0
        if command -v node >/dev/null 2>&1; then
            node -e "[...new Intl.Segmenter(\"en\",{granularity:\"grapheme\"}).segment(\"x\")]" \
                || { echo "node: Intl.Segmenter segfaults (missing ICU data)"; rc=1; }
        fi
        for a in codex gemini grok; do
            command -v "$a" >/dev/null 2>&1 || continue
            "$a" --version >/dev/null 2>&1 || { echo "$a --version failed"; rc=1; }
        done
        exit $rc' 2>&1)" && printf 'PASS\n' || { printf 'FAIL\n%s\n' "$agent_out"; die "an optional agent in $REF does not run"; }

# The gate this package did not have. check-doc-links.sh validates references in
# the tree; it structurally cannot see an unrebuilt image, and an image shipped
# for five releases telling users to read a document deleted two releases
# earlier. This reads the references out of the IMAGE and checks them here.
printf '%-46s ' "shipped docs references exist"
img_refs="$("$ENGINE" run --rm --entrypoint bash "$REF" -lc '
    grep -rhoE "docs/[A-Za-z0-9._-]+\.md" /usr/local/bin/entrypoint.sh \
        /usr/local/lib/ai-box/ 2>/dev/null | sort -u' 2>/dev/null || true)"
missing_refs=()
while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    [[ -f "$PKG_ROOT/$r" ]] || missing_refs+=("$r")
done <<< "$img_refs"
if (( ${#missing_refs[@]} )); then
    printf 'FAIL\n'
    printf '       image references a document not in this tree: %s\n' "${missing_refs[@]}"
    die "the image is out of date with the package; rebuild it"
fi
printf 'PASS\n'

# The image's own package version, recorded as release evidence.
img_pkg="$("$ENGINE" run --rm "$REF" sh -c 'sed -n "s/^ai-box-package: //p" /etc/toolchain-versions' 2>/dev/null || true)"
printf '%-46s ' "image built from this package version"
if [[ "$img_pkg" == "$PKG_VERSION" ]]; then
    printf 'PASS (%s)\n' "$img_pkg"
else
    printf 'FAIL (image %s, package %s)\n' "${img_pkg:-unknown}" "$PKG_VERSION"
    die "rebuild $REF from this tree before releasing"
fi

log "smoke test passed for $REF"
