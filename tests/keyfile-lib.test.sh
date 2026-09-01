#!/usr/bin/env bash
# The parser hard rule 13 exists for. Both historical bugs are named cases:
# a `kind:` line with no space after the colon was once exported AS the key,
# and a secret containing `=` was truncated at the first one. Both produced an
# unexplained HTTP 401 and neither was reproducible with the other parser copy.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/_harness.sh"
source "$HERE/../shared/keyfile-lib.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk() { printf '%b' "$2" > "$T/$1"; printf '%s' "$T/$1"; }

f="$(mk plain.key 'sk-ant-api03-PLAIN\n')"
is "bare value"                    "$(aibox_key_value "$f")" 'sk-ant-api03-PLAIN'
is "kind guessed from prefix"      "$(aibox_key_kind "$f")"  'api'

f="$(mk nospace.key 'kind:api\nsk-ant-api03-SECRET\n')"
is "kind: with no space (regression)" "$(aibox_key_value "$f")" 'sk-ant-api03-SECRET'
is "  and its kind"                   "$(aibox_key_kind "$f")"  'api'

f="$(mk equals.key 'kind: bearer\nabc=def=ghi==\n')"
is "secret containing = (regression)" "$(aibox_key_value "$f")" 'abc=def=ghi=='

f="$(mk assign.key 'ANTHROPIC_API_KEY=sk-ant-api03-XYZ\n')"
is "known NAME=value is stripped"  "$(aibox_key_value "$f")" 'sk-ant-api03-XYZ'
f="$(mk weird.key 'WEIRD=sk-ant-api03-XYZ\n')"
is "unknown NAME= is NOT stripped" "$(aibox_key_value "$f")" 'WEIRD=sk-ant-api03-XYZ'

f="$(mk crlf.key '# note\r\nkind: oauth\r\nsk-ant-oat01-TOK\r\n')"
is "CRLF and comments"             "$(aibox_key_value "$f")" 'sk-ant-oat01-TOK'

f="$(mk empty.key '# only a comment\nkind: api\n')"
fails "no value line is an error"  aibox_key_value "$f"

is "api    -> variable" "$(aibox_key_var api)"    'ANTHROPIC_API_KEY'
is "oauth  -> variable" "$(aibox_key_var oauth)"  'CLAUDE_CODE_OAUTH_TOKEN'
is "bearer -> variable" "$(aibox_key_var bearer)" 'ANTHROPIC_AUTH_TOKEN'
is "gemini -> variable" "$(aibox_key_var gemini)" 'GEMINI_API_KEY'
is "openai -> variable" "$(aibox_key_var openai)" 'OPENAI_API_KEY'
# XAI_API_KEY is the name xAI documents; the CLI also accepts the older
# GROK_CODE_XAI_API_KEY, which stays on the allowlist but is not what we export.
is "grok   -> variable" "$(aibox_key_var grok)"   'XAI_API_KEY'

succeeds "allowlist accepts a key variable" aibox_key_var_ok ANTHROPIC_API_KEY
fails    "allowlist rejects PATH"           aibox_key_var_ok PATH
fails    "allowlist rejects LD_PRELOAD"     aibox_key_var_ok LD_PRELOAD

is "xai- prefix"      "$(aibox_key_kind_of_value 'xai-abc')"      'grok'
is "sk-proj- prefix"  "$(aibox_key_kind_of_value 'sk-proj-abc')"  'openai'
is "AIza prefix"      "$(aibox_key_kind_of_value 'AIzaSyABC')"    'gemini'
is "sk-ant-oat"       "$(aibox_key_kind_of_value 'sk-ant-oat01')" 'oauth'
is "unrecognised"     "$(aibox_key_kind_of_value 'hello')"        'unknown'
finish
