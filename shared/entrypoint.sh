#!/usr/bin/env bash
# Shared container entrypoint for every image images.
# Keep this distro-agnostic: it is COPYed into both images from shared/.
set -euo pipefail

# shellcheck source=keyfile-lib.sh
source /usr/local/lib/ai-box/keyfile-lib.sh

# Optional agents keep their state in their own home directories, which live in
# the container's ephemeral layer: a --rm run threw away grok's and gemini's
# logins and sessions while claude's survived, because only ~/.claude is mounted.
# Pointing them inside that existing mount fixes it without adding a bind.
mkdir -p "${HOME}/.claude/agents/grok" "${HOME}/.claude/agents/gemini" \
         "${HOME}/.claude/agents/codex" 2>/dev/null || true
mkdir -p "${HOME}/.claude" 2>/dev/null || true

# ---- caches ---------------------------------------------------------------
# ~/.cache is a symlink into the workspace, and XDG_CACHE_HOME and CCACHE_DIR point
# there too, so every cache belongs to the project and is deleted with it.
#
# A dangling symlink is worse than no symlink: `mkdir -p ~/.cache/pip` where ~/.cache
# points at a path that does not exist fails with "File exists", because mkdir finds
# the symlink, cannot stat through it, and refuses. So the targets are created here,
# before anything can want them.
#
# The workspace is not always writable, and is not always mounted at all:
# smoke-test.sh mounts a project read-only, and `docker run --rm IMG cat
# /etc/toolchain-versions` mounts nothing. Both must keep working, so an unusable
# workspace falls back to the tmpfs rather than failing.
_cache_ok=1
if [[ -d /workspace && -w /workspace ]]; then
    for _d in "${XDG_CACHE_HOME:-}" "${CCACHE_DIR:-}"; do
        [[ -n "$_d" ]] || continue
        mkdir -p "$_d" 2>/dev/null || _cache_ok=0
        # Self-ignoring, so no project has to remember a .gitignore entry and nobody
        # commits a cache. Written once; never overwritten if the user edits it.
        # Braces, so 2>/dev/null covers the redirection itself: bash reports a
        # failed redirect before the command runs, so a plain `printf ... 2>/dev/null`
        # still prints "Permission denied" when the directory is not writable.
        if [[ ! -e "${_d}/.gitignore" ]]; then
            { printf '*\n' > "${_d}/.gitignore"; } 2>/dev/null || true
        fi
    done
else
    _cache_ok=0
fi

if (( ! _cache_ok )); then
    # /tmp is a tmpfs, so this costs nothing and disappears with the container.
    export XDG_CACHE_HOME=/tmp/cache
    export CCACHE_DIR=/tmp/cache/ccache
    mkdir -p "$XDG_CACHE_HOME" "$CCACHE_DIR" 2>/dev/null || true
    if [[ -t 2 ]]; then
        printf 'ai-box: /workspace is not writable; caches are in /tmp for this session only\n' >&2
    fi
fi
unset _cache_ok _d

# ---- credential from a mounted file ---------------------------------------
# A key mounted as a file never appears in `docker inspect` or in the process
# list on the host, unlike anything passed with -e / --env.
#
#   /run/secrets/ai-key              preferred path (any credential kind)
#   /run/secrets/anthropic_api_key   oldest legacy path, always an API key
#
# AI_BOX_KEY_VAR names the environment variable to export, so the same
# mechanism carries an API key, a long-lived OAuth token, or a gateway bearer
# token. Claude Code's precedence means exporting the wrong one silently wins
# over the right one, so ai-box sets this from the key file's own metadata.
# If it is absent or names something unexpected, fall back to reading the kind
# out of the file with the same parser the host used.
_load_key_file() {
    local path="$1" var="${2:-}" value
    [[ -r "$path" ]] || return 1
    value="$(aibox_key_value "$path")" || return 1
    if [[ -z "$var" ]] || ! aibox_key_var_ok "$var"; then
        var="$(aibox_key_var "$(aibox_key_kind "$path")")"
    fi
    printf -v "$var" '%s' "$value"
    export "${var?}"
    return 0
}

if [[ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    _load_key_file /run/secrets/ai-key "${AI_BOX_KEY_VAR:-}" \
        || _load_key_file /run/secrets/anthropic_api_key ANTHROPIC_API_KEY \
        || true
fi

# Extra non-secret settings that travel with a key profile (base URL, model).
# The companion .env carries non-secret routing settings (base URL, model).
# It is READ, never sourced. The host config file is parsed for exactly this
# reason -- a file that can execute code sits on the credential side of the
# boundary -- and this file is the same class: it lives in the key store, and a
# compose user can mount anything at this path. Only known names are exported.
_load_key_env() {
    local file="$1" line key value
    [[ -r "$file" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; key="${key//[[:space:]]/}"
        value="${line#*=}"
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"
        case "$key" in
            ANTHROPIC_BASE_URL|ANTHROPIC_MODEL|ANTHROPIC_SMALL_FAST_MODEL|\
            ANTHROPIC_CUSTOM_HEADERS|CLAUDE_CODE_MAX_OUTPUT_TOKENS|\
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC|DISABLE_TELEMETRY|\
            HTTP_PROXY|HTTPS_PROXY|NO_PROXY|NODE_EXTRA_CA_CERTS|\
            GOOGLE_CLOUD_PROJECT|OPENAI_BASE_URL)
                printf -v "$key" '%s' "$value"; export "${key?}" ;;
            *) printf 'entrypoint: ignoring unknown setting in key .env: %s\n' "$key" >&2 ;;
        esac
    done < "$file"
}
_load_key_env /run/secrets/ai-key-env

# ---- git ------------------------------------------------------------------
# The bind-mounted project is owned by the host user; keep git quiet about it.
if command -v git >/dev/null 2>&1; then
    git config --global --get-all safe.directory 2>/dev/null | grep -qx '/workspace' \
        || git config --global --add safe.directory '/workspace' 2>/dev/null || true
fi

# ---- first-run hint, interactive shells only ------------------------------
if [[ -t 1 && "${1:-}" == *bash* && ! -e "${HOME}/.claude/.ai-box-greeted" ]]; then
    if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then _auth="ANTHROPIC_AUTH_TOKEN (mounted)"
    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then _auth="ANTHROPIC_API_KEY (mounted)"
    elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then _auth="CLAUDE_CODE_OAUTH_TOKEN (mounted)"
    elif [[ -s "${HOME}/.claude/.credentials.json" ]]; then _auth="stored /login credential"
    else _auth="none. Run 'claude' and log in, or see docs/credentials.md"; fi
    cat <<BANNER
ai-box: isolated container. /workspace is the only host directory mounted.
  credential: ${_auth}
  claude                                  start the agent (prompts for permissions)
  claude --dangerously-skip-permissions   start unattended (nothing else is mounted)
  cat /etc/toolchain-versions             what compilers this image ships
BANNER
    unset _auth
    touch "${HOME}/.claude/.ai-box-greeted" 2>/dev/null || true
fi

exec "$@"
