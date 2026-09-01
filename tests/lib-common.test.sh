#!/usr/bin/env bash
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/_harness.sh"
HOME="$(mktemp -d)"; export HOME; trap 'rm -rf "$HOME"' EXIT
export AI_BOX_CONFIG="$HOME/.config/ai-box" AI_KEYS_DIR="$HOME/.aikeys"
export AI_BOX_STATE="$HOME/.local/share/ai-box"
source "$HERE/../scripts/lib-common.sh"

# safe_hostname: the constraint is the kernel's 64-byte label limit, and the
# tag must stay readable rather than being truncated at the first colon.
is "keeps the tag readable" "$(safe_hostname 'ai-fedora:44-cc2.1.211')" 'ai-box-ai-fedora-44-cc2-1-211'
is "simple key"             "$(safe_hostname ubuntu)"                   'ai-box-ubuntu'
is "registry ref"           "$(safe_hostname 'reg.io:5000/t/i:1.2')"    'ai-box-reg-io-5000-t-i-1-2'
long="$(safe_hostname "$(printf 'a%.0s' {1..90})")"
is "capped at 63"           "${#long}"                                  '63'
is "never trailing hyphen"  "${long: -1}"                               'a'
is "degenerate input"       "$(safe_hostname '::::')"                   'ai-box'

is "image_ref ubuntu" "$(image_ref ubuntu)" "$UBUNTU_IMAGE"
is "image_ref fedora" "$(image_ref fedora)" "$FEDORA_IMAGE"
is "image_ref rocky"  "$(image_ref rocky)"  "$ROCKY_IMAGE"
is "image_ref passes a full reference through" "$(image_ref 'foo/bar:1')" 'foo/bar:1'

is "prefers the current location once it exists" "$(state_dir ai-fedora:44)" \
   "$AI_BOX_STATE/ai-fedora_44"

# resolve_key_profile precedence
proj="$HOME/proj"; mkdir -p "$proj" "$AI_KEYS_DIR/projects"
is "default when nothing else applies" "$(resolve_key_profile "$proj")" 'default'
printf 'linked\n' > "$AI_KEYS_DIR/projects/proj"
is "a project pin"                     "$(resolve_key_profile "$proj")" 'linked'
printf 'inrepo\n' > "$proj/.ai-profile"
is ".ai-profile outranks the pin"      "$(resolve_key_profile "$proj")" 'inrepo'
# shellcheck disable=SC2030,SC2031  # exported for the subshell under test only
_got="$(export AI_BOX_KEY_PROFILE=env; resolve_key_profile "$proj")"
is "environment outranks all" "$_got" 'env'

# The guard must refuse every vendor's credential, not only Anthropic's.
for k in sk-ant-api03-X xai-X sk-proj-X AIzaSyX; do
    printf '%s\n' "$k" > "$proj/.ai-profile"
    fails "refuses a credential in .ai-profile: ${k:0:8}" assert_profile_file_sane "$proj"
done
printf 'a-name\n' > "$proj/.ai-profile"
succeeds "accepts a profile name" assert_profile_file_sane "$proj"

# json_ok is a shell function, so call it directly: `bash -c` would not have it.
printf '{"a":1}' > "$HOME/j1"; : > "$HOME/j2"; printf '{"a":' > "$HOME/j3"
succeeds "json_ok accepts valid JSON" json_ok "$HOME/j1"
fails    "json_ok rejects empty"      json_ok "$HOME/j2"
fails    "json_ok rejects truncated"  json_ok "$HOME/j3"

# install.sh discovers scripts rather than listing them. A hand-maintained list
# drifted silently for nine releases: seven scripts were in the package and never
# linked, so `ai-box-capabilities` did not exist on anyone's PATH.
inst="$HOME/bin"; mkdir -p "$inst"
( AI_BOX_BIN="$inst" AI_BOX_CONFIG="$HOME/c" AI_BOX_STATE="$HOME/s" AI_KEYS_DIR="$HOME/k" \
  bash "$HERE/../scripts/install.sh" ) >/dev/null 2>&1
for want in ai-box ai-keys ai-box-capabilities ai-box-doctor ai-box-build \
            ai-box-verify-isolation ai-box-smoke-test ai-box-check-doc-links; do
    [[ -L "$inst/$want" ]] && ok "install links $want" || fail "install links $want" present missing
done
[[ -e "$inst/lib-common" ]] && fail "does not link the sourced library" absent present \
                            || ok "does not link the sourced library"

# Location detection. Both markers are required: a host that has ever had
# toolchain-report.sh run on it carries /etc/toolchain-versions, and a shell
# profile can export AI_BOX_IMAGE. Either alone must not count.
marker=/etc/toolchain-versions
if [[ -r "$marker" ]]; then
    is "marker alone is not enough"      "$(unset AI_BOX_IMAGE; in_ai_box && echo yes || echo no)" 'no'
    is "both markers detect the box"     "$(AI_BOX_IMAGE=fedora; export AI_BOX_IMAGE; in_ai_box && echo yes || echo no)" 'yes'
else
    is "variable alone is not enough"    "$(AI_BOX_IMAGE=fedora; export AI_BOX_IMAGE; in_ai_box && echo yes || echo no)" 'no'
fi
is "neither marker: plain host"          "$(unset AI_BOX_IMAGE; in_ai_box && echo yes || echo no)" 'no'


# --version and --help must work with no engine, no keys and no images: they are
# the two commands someone runs when nothing else is working.
AIBOX="$HERE/../scripts/ai-box"
out="$(PATH=/nonexistent:/usr/bin:/bin "$AIBOX" --version 2>&1)" && vrc=0 || vrc=1
is  "--version exits 0 without an engine" "$vrc" '0'
case "$out" in *"ai-box $(cat "$HERE/../VERSION")"*) ok "--version prints the package version" ;;
              *) fail "--version prints the package version" "version line" "$out" ;; esac
case "$out" in *"package   "*) ok "--version prints the package location" ;;
              *) fail "--version prints the package location" "package line" "$out" ;; esac
case "$out" in *releases*) ok "--version says where newer releases are" ;;
              *) fail "--version says where newer releases are" "a releases URL" "$out" ;; esac

out="$(PATH=/nonexistent:/usr/bin:/bin "$AIBOX" --help 2>&1)" && hrc=0 || hrc=1
is "--help exits 0 without an engine" "$hrc" '0'
case "$out" in *"installed:"*) ok "--help says where the package is installed" ;;
              *) fail "--help says where the package is installed" "installed block" "$out" ;; esac


# --tty must not be passed when there is no terminal. Passing it unconditionally
# made every non-interactive use fail with "the input device is not a TTY": CI
# jobs, cron, pipelines, and this package's own verify-isolation.sh.
proj="$HOME/tty-proj"; mkdir -p "$proj"
# --dry-run prints one argument per line, so match lines. A space-delimited
# match passed the absence case by accident and failed the presence one, which
# is a reminder that a green assertion is not the same as a correct one.
argv="$("$HERE/../scripts/ai-box" -n -p "$proj" -a none -- true </dev/null 2>/dev/null || true)"
if printf '%s\n' "$argv" | grep -qx -- '--tty'; then
    fail "no --tty without a terminal" "--tty absent" "--tty present"
else
    ok "no --tty without a terminal"
fi
if printf '%s\n' "$argv" | grep -qx -- '--interactive'; then
    ok "--interactive is kept regardless"
else
    fail "--interactive is kept regardless" "present" "absent"
fi

finish
