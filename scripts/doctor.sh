#!/usr/bin/env bash
# ai-box-doctor -- check the host-side setup before blaming the container.
#
# Everything this checks has caused a real failure at least once: an empty
# .claude.json, a key file with the wrong mode, a key sitting inside a project
# directory, a state directory left over from a previous image tag, a stale
# single-file config mount. Read-only by default: it reports, it does not
# repair, except where --fix is given, and --fix only touches the mechanical
# problems (file modes, the legacy config layout, an unparseable config file).
# Judgement calls -- a key in the wrong place, a missing image -- it leaves alone.
#
# The helpers are named ok/bad/note rather than pass/fail because `pass` is also
# the name of the password manager this project reads credentials from, and a
# shell function shadowing it is exactly the kind of surprise a doctor should
# not introduce.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

FIX=0
PROJECT_DIR="$PWD"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)        FIX=1; shift ;;
        -p|--project) PROJECT_DIR="${2:?}"; shift 2 ;;
        -h|--help)    echo "usage: doctor.sh [--fix] [-p PROJECT_DIR]"; exit 0 ;;
        *)            die "unknown option: $1" ;;
    esac
done

RC=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; RC=1; }
note() { printf '  \033[33mnote\033[0m  %s\n' "$*"; }

section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

section "package"
ok "ai-box $PKG_VERSION at $PKG_ROOT"

section "container engine"
if command -v "$ENGINE" >/dev/null 2>&1; then
    if "$ENGINE" info >/dev/null 2>&1; then
        ok "$ENGINE reachable ($("$ENGINE" version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"
    elif [[ "$ENGINE" == docker ]]; then
        bad "docker installed but not reachable; is the daemon running, are you in the docker group?"
    else
        bad "podman installed but not usable; try 'podman info' and check subuid/subgid delegation"
    fi
    if [[ "$ENGINE" == podman ]]; then
        # Rootless podman needs a subordinate ID range for the calling user, and
        # without one every container start fails with a message about newuidmap.
        if grep -q "^${USER}:" /etc/subuid 2>/dev/null; then
            ok "subuid range delegated to $USER"
        else
            note "no /etc/subuid entry for $USER; rootless podman needs one (usermod --add-subuids)"
        fi
    fi
elif [[ "$ENGINE" == docker ]] && command -v podman >/dev/null 2>&1; then
    note "docker not found but podman is; set AI_BOX_ENGINE=podman (see README.md, Podman)"
else
    bad "$ENGINE not installed"
fi

section "images"
for key in "${ALL_IMAGE_KEYS[@]}"; do
    ref="$(image_ref "$key")"
    if image_exists "$ref"; then
        cc="$(installed_claude_version "$ref")"
        upd="$("$ENGINE" image inspect "$ref" \
               --format '{{index .Config.Labels "com.ai-box.os-updates"}}' 2>/dev/null || true)"
        stamp="$("$ENGINE" image inspect "$ref" \
               --format '{{index .Config.Labels "com.ai-box.update-stamp"}}' 2>/dev/null || true)"
        # Every gate in this package checks the tree; none compared the tree to a
        # built image, which is how five releases of drift accumulated with
        # everything green. Report it here rather than fail: there are legitimate
        # reasons to run an older image.
        img_pkg="$("$ENGINE" image inspect "$ref" \
                   --format '{{index .Config.Labels "com.ai-box.package-version"}}' 2>/dev/null || true)"
        case "$img_pkg" in ''|'<no value>')
            img_pkg="$("$ENGINE" run --rm "$ref" \
                sh -c 'sed -n "s/^ai-box-package: //p" /etc/toolchain-versions' 2>/dev/null || true)" ;;
        esac

        ok "$ref  claude=$cc os-updates=${upd:-?} stamp=${stamp:-?}"

        if [[ -n "$img_pkg" && "$img_pkg" != "$PKG_VERSION" ]]; then
            note "$ref  built from package $img_pkg, this wrapper is $PKG_VERSION"
            note "      rebuild to close the gap:  ai-box-build $key"
        fi

        # Deriving from a published base refreshes OS packages but not the agent:
        # Claude Code comes from the signed repository baked into the base image
        # and is pinned by its tag, so a base published two months ago carries a
        # two-month-old agent even with OS_UPDATES=1. Nothing said so before.
        want="$(channel_candidate "$key" 2>/dev/null || true)"
        if [[ -n "$want" && "$want" != unknown && "${want%%-*}" != "$cc" ]]; then
            note "$ref  Claude Code $cc, the channel offers ${want%%-*}"
            note "      OS updates do not refresh the agent:  ai-box-upgrade $key"
        fi
    else
        note "$ref not built; scripts/build.sh $key"
    fi
done

section "credential store"
if [[ -d "$KEYS_DIR" ]]; then
    mode="$(stat -c '%a' "$KEYS_DIR")"
    if [[ "$mode" == 700 ]]; then
        ok "$KEYS_DIR mode 0700"
    elif (( FIX )); then
        chmod 700 "$KEYS_DIR"; ok "$KEYS_DIR mode fixed to 0700"
    else
        bad "$KEYS_DIR is mode $mode; chmod 700 (or rerun with --fix)"
    fi

    found=0
    for f in "$KEYS_DIR"/*.key; do
        [[ -e "$f" ]] || continue
        found=1
        fmode="$(stat -c '%a' "$f")"
        kind="$(aibox_key_kind "$f")"
        if [[ "$fmode" == 600 || "$fmode" == 400 ]]; then
            if var="$(aibox_key_var "$kind")"; then
                ok "$(basename "$f") mode $fmode kind=$kind -> $var"
            else
                fail "$(basename "$f") declares an unknown kind: $kind"
            fi
        elif (( FIX )); then
            chmod 600 "$f"; ok "$(basename "$f") mode fixed to 0600"
        else
            bad "$(basename "$f") is mode $fmode; chmod 600 (or rerun with --fix)"
        fi
        # A profile with no value line parses to nothing and presents inside the
        # container as an unexplained HTTP 401, which is why this is checked here
        # with the same parser the container uses.
        if ! aibox_key_value "$f" >/dev/null 2>&1; then
            bad "$(basename "$f") has no value line; the container would start with no credential"
        fi
    done
    if (( ! found )); then
        note "no key profiles yet; ai-keys add default"
    fi
else
    note "no key store at $KEYS_DIR; ai-keys init (or use -a login)"
fi

section "project: $PROJECT_DIR"
profile="$(resolve_key_profile "$PROJECT_DIR")"
if [[ -r "$KEYS_DIR/$profile.key" ]]; then
    ok "resolves to key profile '$profile'"
else
    note "resolves to profile '$profile', which has no key file; will fall back to browser login"
fi
# A key inside the project is the mistake ai-box refuses at run time.
while IFS= read -r stray; do
    [[ -n "$stray" ]] || continue
    bad "credential-looking file inside the project: $stray; move it with ai-keys add"
done < <(find "$PROJECT_DIR" -maxdepth 2 \( -name '*.key' -o -name '.aikeys*' -o -name 'anthropic*.env' \) \
             -not -path '*/.git/*' 2>/dev/null || true)
if [[ -r "$PROJECT_DIR/.ai-profile" ]]; then
    if grep -qE '^[[:space:]]*sk-ant-' "$PROJECT_DIR/.ai-profile" 2>/dev/null; then
        bad ".ai-profile holds what looks like a KEY, not a profile name. That file is
        meant to be committed, so revoke the key before doing anything else."
    else
        ok ".ai-profile names profile '$(head -1 "$PROJECT_DIR/.ai-profile")'"
    fi
fi
# The same directories ai-box refuses as a project argument.
case "$PROJECT_DIR" in
    "$HOME"|/|/home|/root|/etc|/usr|/var|/opt|/boot|/proc|/sys|/dev|/srv|/mnt|/media)
        bad "ai-box refuses to mount $PROJECT_DIR; run it from one project directory" ;;
esac

section "per-image state"
shopt -s nullglob
for d in "$STATE_ROOT"/*/; do
    name="$(basename "$d")"
    cfg="$d/claude/.claude.json"
    legacy="$d/claude.json"

    if [[ -e "$legacy" ]]; then
        if (( FIX )); then
            if json_ok "$legacy" && [[ ! -e "$cfg" ]]; then mv "$legacy" "$cfg"; else rm -f "$legacy"; fi
            ok "$name: migrated legacy claude.json"
        else
            note "$name: legacy claude.json present; ai-box migrates it on next run, or use --fix"
        fi
    fi

    if [[ -e "$cfg" ]]; then
        if json_ok "$cfg"; then
            ok "$name: .claude.json valid"
        elif (( FIX )); then
            mkdir -p "$d/claude/backups"
            mv "$cfg" "$d/claude/backups/.claude.json.corrupted.$(date +%s)"
            printf '{}\n' > "$cfg"
            ok "$name: .claude.json was invalid, backed up and reset"
        else
            bad "$name: .claude.json is not valid JSON; rerun with --fix, or ai-box repairs it on next run"
        fi
    fi

    if [[ -s "$d/claude/.credentials.json" ]]; then
        ok "$name: stored login present"
    fi
done
shopt -u nullglob
[[ -d "$STATE_ROOT" ]] || note "no state yet at $STATE_ROOT; created on first run"

section "summary"
if (( RC == 0 )); then
    printf '  no problems found\n'
else
    printf '  problems found; rerun with --fix where the message says so\n'
fi
exit $RC
