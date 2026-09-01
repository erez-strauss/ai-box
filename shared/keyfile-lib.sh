#!/usr/bin/env bash
# The one parser for ai-box key-profile files. Source, do not execute.
#
# This file is sourced in two places that must never disagree:
#   * on the host, by scripts/lib-common.sh, so ai-box and ai-keys read
#     a profile the same way;
#   * inside both images, by shared/entrypoint.sh, from
#     /usr/local/lib/ai-box/keyfile-lib.sh.
# Before 1.4.0 there were three separate implementations of this logic and they
# disagreed on two real inputs (a "kind:api" line with no space after the colon,
# and a secret containing "="), which showed up as an unexplained HTTP 401 that
# `ai-keys test` could not reproduce.
#
# File format, one profile per file:
#
#     # free-form comment
#     kind: api                  metadata: name, colon, value
#     sk-ant-api03-...           the secret: first line that is neither
#
# The secret may be written bare or as NAME=value. Only the metadata names in
# AIBOX_KEY_META_NAMES below are recognised as metadata; every other line is a
# candidate secret, so a key is never mistaken for a header.

# Metadata names, as an alternation for a POSIX ERE. "kind" is the only one the
# tooling acts on; the rest exist so hand-written notes do not become the key.
AIBOX_KEY_META_NAMES='kind|added|note|label|profile|desc|comment|source'

# Variable names a profile may prefix its secret with. Deliberately a closed
# list: "strip everything up to the first =" truncates a bare secret that
# contains one, and base64-ish tokens end in "=" often enough to matter.
AIBOX_KEY_ASSIGN_NAMES='ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_KEY|API_KEY|TOKEN|KEY'

# aibox_key_value <file> -> the secret on stdout, or non-zero if there is none
aibox_key_value() {
    local file="$1" line value=""
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*($AIBOX_KEY_META_NAMES)[[:space:]]*: ]]; then
            continue
        fi
        value="$line"
        break
    done < "$file"

    # "NAME=value" for a known NAME only. Stripping through the first "="
    # unconditionally truncated any bare secret that happened to contain one.
    if [[ "$value" =~ ^($AIBOX_KEY_ASSIGN_NAMES)[[:space:]]*= ]]; then
        value="${value#*=}"
    fi
    value="${value#"${value%%[![:space:]]*}"}"   # trim leading whitespace
    value="${value%"${value##*[![:space:]]}"}"   # trim trailing whitespace
    [[ -n "$value" ]] || return 1
    printf '%s' "$value"
}

# aibox_key_kind_of_value <secret> -> api | oauth | unknown
# Prefixes are a convenience. A "kind:" line in the file always wins.
aibox_key_kind_of_value() {
    case "$1" in
        sk-ant-oat*) printf 'oauth' ;;
        xai-*)       printf 'grok' ;;
        sk-proj-*|sk-svcacct-*) printf 'openai' ;;
        AIza*)       printf 'gemini' ;;
        sk-ant-*)    printf 'api' ;;
        *)           printf 'unknown' ;;
    esac
}

# aibox_key_kind <file> -> declared kind, else guessed from the prefix
aibox_key_kind() {
    local file="$1" declared value
    declared="$(sed -n "s/^[[:space:]]*kind[[:space:]]*:[[:space:]]*//p" "$file" 2>/dev/null \
                | head -1 | tr -d '\r\n[:space:]')"
    if [[ -n "$declared" ]]; then
        printf '%s' "$declared"
        return 0
    fi
    value="$(aibox_key_value "$file" 2>/dev/null || true)"
    aibox_key_kind_of_value "$value"
}

# aibox_key_var <kind> -> the environment variable Claude Code reads for it.
# Claude Code's precedence is cloud provider, ANTHROPIC_AUTH_TOKEN,
# ANTHROPIC_API_KEY, apiKeyHelper, CLAUDE_CODE_OAUTH_TOKEN, then the stored
# login, so exporting the wrong variable silently outranks the right credential.
aibox_key_var() {
    case "$1" in
        oauth)  printf 'CLAUDE_CODE_OAUTH_TOKEN' ;;
        bearer) printf 'ANTHROPIC_AUTH_TOKEN' ;;
        # Other vendors' agents, when built in with --agents. Each reads its own
        # variable; there is no shared convention, so the profile's kind: line
        # is the only reliable way to know which one a key belongs to.
        gemini) printf 'GEMINI_API_KEY' ;;
        openai) printf 'OPENAI_API_KEY' ;;
        # XAI_API_KEY is the name xAI documents; GROK_CODE_XAI_API_KEY is
        # accepted by the CLI for backward compatibility. Prefer the canonical one.
        grok)   printf 'XAI_API_KEY' ;;
        api)    printf 'ANTHROPIC_API_KEY' ;;
        # No silent default. A typo in `kind:` used to become an Anthropic key,
        # which is the failure hard rule 11 exists to prevent: the wrong variable
        # silently outranks the right credential and the error surfaces as an
        # unexplained 401 from a vendor the key does not belong to.
        *)      return 1 ;;
    esac
}

# aibox_key_var_ok <name> -- is this one of the variables we may export?
# Guards the container against a AI_BOX_KEY_VAR that names something else.
aibox_key_var_ok() {
    case "$1" in
        ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN) return 0 ;;
        GEMINI_API_KEY|OPENAI_API_KEY|XAI_API_KEY|GROK_CODE_XAI_API_KEY) return 0 ;;
        *) return 1 ;;
    esac
}
