#!/usr/bin/env bash
# Shared definitions for the ai-box scripts. Source, do not execute.

PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck disable=SC2034  # consumed by the scripts that source this file
PKG_VERSION="$(< "${PKG_ROOT}/VERSION")"

# The key-file parser lives in shared/ because the container needs it too.
# shellcheck source=../shared/keyfile-lib.sh
source "${PKG_ROOT}/shared/keyfile-lib.sh"

CONFIG_ROOT="${AI_BOX_CONFIG:-$HOME/.config/ai-box}"
KEYS_DIR="${AI_KEYS_DIR:-$HOME/.aikeys}"

# ---- optional persistent settings ------------------------------------------
# ~/.config/ai-box/config holds KEY=value lines. It is READ, never sourced:
# a config file that can execute code would be a way to reach into every future
# container, and this file is on the credential side of the boundary. Only the
# names below are honoured, and an environment variable always wins, so a
# one-off `AI_BOX_DEFAULT_IMAGE=ubuntu ai-box` still works.
#
# Loaded BEFORE the defaults below, so the config can actually change them.
_load_config() {
    local file="${CONFIG_ROOT}/config" key value
    [[ -r "$file" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; key="${key//[[:space:]]/}"
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"     # trim leading space
        value="${value%"${value##*[![:space:]]}"}"     # trim trailing space
        value="${value%\"}"; value="${value#\"}"       # tolerate quotes
        value="${value%\'}"; value="${value#\'}"
        case "$key" in
            AI_BOX_DEFAULT_IMAGE|AI_BOX_UBUNTU_IMAGE|AI_BOX_FEDORA_IMAGE|\
            AI_BOX_ROCKY_IMAGE|AI_BOX_MEMORY|AI_BOX_CPUS|AI_BOX_ENGINE|\
            AI_BOX_AUTH|AI_BOX_KEY_PROFILE)
                [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$value" ;;
            *) : ;;   # anything else is ignored, silently and on purpose
        esac
    done < "$file"
}
_load_config

UBUNTU_IMAGE="${AI_BOX_UBUNTU_IMAGE:-ai-ubuntu:26.04}"
FEDORA_IMAGE="${AI_BOX_FEDORA_IMAGE:-ai-fedora:44}"
ROCKY_IMAGE="${AI_BOX_ROCKY_IMAGE:-ai-rocky:10}"

# Which image `ai-box` uses when -i is not given. Fedora by default since
# 1.7.0: it carries the newest compilers of the three. Override per-shell with
# AI_BOX_DEFAULT_IMAGE, or permanently with a line in the config file.
# shellcheck disable=SC2034  # read by ai-box
DEFAULT_IMAGE_KEY="${AI_BOX_DEFAULT_IMAGE:-fedora}"

STATE_ROOT="${AI_BOX_STATE:-$HOME/.local/share/ai-box}"

# The compatibility fallback was removed in 2.1.1, so state left under the old
# root is simply not found and the agent asks for a fresh login. That is a
# confusing way to discover an upgrade, so say it once, with the command.
if [[ -d "$HOME/.local/share/claude-box" ]]; then
    printf '\033[1;33m warn:\033[0m state found under the pre-2.0.0 path %s\n' \
        "$HOME/.local/share/claude-box" >&2
    printf '       It is no longer read. Move it once to keep your logins:\n' >&2
    printf '         mv %s/* %s/ && rmdir %s\n' \
        "$HOME/.local/share/claude-box" "$STATE_ROOT" "$HOME/.local/share/claude-box" >&2
fi

# Every image this package builds, in build order. Scripts iterate over this
# rather than hardcoding a list, so adding an image is one edit here.
# shellcheck disable=SC2034  # read by build.sh, upgrade.sh, doctor.sh, check-updates.sh
ALL_IMAGE_KEYS=(ubuntu fedora rocky)

# Where published base images live. Published images carry no optional agents;
# `build.sh --pull` derives a local image from one, adding agents and updates.
REGISTRY="${AI_BOX_REGISTRY:-ghcr.io/erez-strauss}"

# Where a user checks for a newer release. Referenced by --help and --version so
# the answer is in the tool rather than only in the README.
PROJECT_URL="${AI_BOX_PROJECT_URL:-https://github.com/erez-strauss/ai-box}"

# where_am_i -- how this command was reached, resolved like `ls -l` shows it.
#
# Almost every installation is a symlink from ~/.local/bin into a package
# directory, so "which version am I running" has two halves: the link the user
# typed and the package it lands in. Printing only one has caused confusion
# before, when a stale symlink pointed at an older extracted tarball.
where_am_i() {
    local self="$1" target
    if [[ -L "$self" ]]; then
        target="$(readlink -f "$self")"
        printf '%s -> %s' "$self" "$target"
    else
        printf '%s' "$(readlink -f "$self")"
    fi
}

# print_version <argv0>
print_version() {
    local self="$1"
    printf 'ai-box %s\n' "$PKG_VERSION"
    printf '  command   %s\n' "$(where_am_i "$self")"
    printf '  package   %s\n' "$PKG_ROOT"
    printf '  engine    %s' "$ENGINE"
    if command -v "$ENGINE" >/dev/null 2>&1; then
        printf ' (%s)\n' "$("$ENGINE" --version 2>/dev/null | head -1)"
    else
        printf ' (not installed)\n'
    fi
    printf '  images    %s\n' "$(
        for k in "${ALL_IMAGE_KEYS[@]}"; do printf '%s ' "$(image_ref "$k")"; done)"
    printf '  releases  %s/releases\n' "$PROJECT_URL"
}

# registry_ref <image-key> -> the published repository for that image, WITHOUT a
# tag. image_ref carries one already (ai-fedora:44), and concatenating produced
# ai-fedora:44:2.1.0, which is not a valid reference. The distro version stays in
# the repository name; the tag is the package version.
registry_ref() {
    local ref; ref="$(image_ref "$1")"
    printf '%s/%s' "$REGISTRY" "${ref%%:*}"
}

# ---- where am I running? ----------------------------------------------------
# The question is deliberately "am I inside an ai-box image", not "am I inside a
# container". The generic question is both unreliable (/.dockerenv is Docker
# only, /run/.containerenv is Podman, cgroup parsing broke with cgroup v2) and
# the wrong thing to gate on: CI runners are frequently containers, and building
# images from one is legitimate. Our own images are identifiable exactly, because
# we put the markers there.
#
# Both markers are required. AI_BOX_IMAGE alone could come from a shell profile;
# /etc/toolchain-versions alone would match an image derived from ours by someone
# else.
in_ai_box() { [[ -n "${AI_BOX_IMAGE:-}" && -r /etc/toolchain-versions ]]; }

# For scripts that drive the container engine from the host.
require_host() {
    in_ai_box || return 0
    die "$(basename "$0") runs on the host, not inside the box.
       You are in the ${AI_BOX_IMAGE} image. Run it from the host checkout.
       Building or starting containers from in here would need the engine
       socket, which this project never mounts."
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# ---- container engine -------------------------------------------------------
# docker by default, podman supported. This is a variable rather than a literal
# because the name appears in about twenty places across the scripts, and a
# second engine spelled out by hand in each of them is precisely the duplication
# this file exists to prevent.
#
# The two are argv-compatible for everything used here. What differs is user
# namespaces: rootless podman maps the caller to container UID 0 and everything
# else to subordinate UIDs, so without --userns=keep-id a file the agent creates
# in /workspace comes out owned by a subuid on the host rather than by you. ai-box
# adds that flag; see the Podman section of README.md.
ENGINE="${AI_BOX_ENGINE:-docker}"
case "$ENGINE" in
    docker|podman) ;;
    *) die "AI_BOX_ENGINE must be docker or podman, not '$ENGINE'" ;;
esac

# Flags every run-as-the-caller container needs, engine-dependent. Kept here so
# ai-box, verify-isolation.sh and smoke-test.sh cannot drift apart on it.
#
# Deliberately NOT applied to channel_candidate below: that one runs --user 0:0,
# and under rootless podman UID 0 is the caller's own mapping, which keep-id
# would take away.
ENGINE_RUN_EXTRA=()
if [[ "$ENGINE" == podman ]]; then
    # shellcheck disable=SC2034  # consumed by ai-box, verify-isolation.sh, smoke-test.sh
    ENGINE_RUN_EXTRA=( --userns=keep-id )
fi

# selinux_relabel_opt -- ",z" when the host enforces SELinux, empty otherwise.
#
# On a Fedora or RHEL host, a bind mount without a relabel option is unreadable
# inside the container and the error says "permission denied" with no hint why.
# "z" is the shared label rather than "Z": the project directory usually belongs
# to other host processes too (an editor, a build server), and the private label
# would take it away from them.
selinux_relabel_opt() {
    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
        printf ',z'
    fi
}

# secret_mount_relabel_opt -- ",relabel=shared" for podman on an SELinux host.
#
# The credential is attached with --mount rather than --volume, and --mount takes
# relabel=... rather than the :z suffix. Docker's --mount has no equivalent
# option at all, so this stays podman-only; a Docker-on-SELinux host needs
# `chcon -t container_file_t` on the key file, which is in README.md.
secret_mount_relabel_opt() {
    if [[ "$ENGINE" == podman ]]; then
        if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
            printf ',relabel=shared'
        fi
    fi
}

# image_ref <ubuntu|fedora|full-ref>
image_ref() {
    case "$1" in
        ubuntu) printf '%s' "$UBUNTU_IMAGE" ;;
        fedora) printf '%s' "$FEDORA_IMAGE" ;;
        rocky)  printf '%s' "$ROCKY_IMAGE" ;;
        *)      printf '%s' "$1" ;;
    esac
}

# dockerfile_for <ubuntu|fedora>
dockerfile_for() {
    case "$1" in
        ubuntu) printf '%s' "docker-ubuntu/Dockerfile.ai-ubuntu" ;;
        fedora) printf '%s' "docker-fedora/Dockerfile.ai-fedora44" ;;
        rocky)  printf '%s' "docker-rocky/Dockerfile.ai-rocky10" ;;
        *)      die "unknown image key: $1 (expected ubuntu, fedora or rocky)" ;;
    esac
}

# state_dir <image-ref> -> per-image persistent state on the host
# state_dir <image-ref> -> where this image's persistent state lives.
#
# The fallback matters more than it looks. State directories are named after the
# image reference, so renaming the images (ai-fedora:44, formerly
# claude-fedora:44) renames the directory too, and the stored login goes with it.
# A root-level fallback is not enough: `install.sh` creates the new state root,
# after which the root exists, the root-level fallback stops firing, and the
# per-image directory underneath is empty. The symptom is being asked to log in
# again on an installation that had a perfectly good credential.
#
# So the fallback is resolved per image, not per root, and it looks in both the
# new root and the old one.
state_dir() { printf '%s/%s' "$STATE_ROOT" "$(printf '%s' "$1" | tr ':/' '__')"; }


# installed_claude_version <image-ref> -> version baked into the image, or "-"
installed_claude_version() {
    "$ENGINE" run --rm --entrypoint claude "$1" --version 2>/dev/null \
        | head -1 | cut -d' ' -f1 || printf '%s' '-'
}

# image_exists <image-ref>
image_exists() { "$ENGINE" image inspect "$1" >/dev/null 2>&1; }

# channel_candidate <ubuntu|fedora> <image-ref> -> the Claude Code version the
# signed channel offers right now, or empty if the repository cannot be queried.
#
# It runs inside the image because that is the only place the signed repository
# is configured, and as root because apt and dnf need to write their own caches.
# Capabilities are deliberately NOT dropped here: apt drops privileges to the
# _apt user to fetch, which needs CAP_SETUID, and without it the query becomes
# unreliable. The container is throwaway, mounts nothing, and only reads
# metadata. no-new-privileges still applies.
channel_candidate() {
    local key="$1" ref="$2" out=""
    local common=(--rm --user 0:0 --security-opt no-new-privileges
                  --pids-limit 512 --entrypoint sh)
    case "$key" in
        ubuntu)
            out="$("$ENGINE" run "${common[@]}" "$ref" -c \
                'apt-get update -qq >/dev/null 2>&1; apt-cache policy claude-code 2>/dev/null | sed -n "s/^ *Candidate: *//p"' \
                2>/dev/null | head -1)" ;;
        fedora|rocky)
            out="$("$ENGINE" run "${common[@]}" "$ref" -c \
                'dnf -q --refresh repoquery --qf "%{version}" --latest-limit 1 claude-code 2>/dev/null' \
                2>/dev/null | tail -1)" ;;
        *)  return 1 ;;
    esac
    printf '%s' "$(printf '%s' "$out" | tr -d '\r' | tr -d '[:space:]')"
}

# resolve_key_profile <project-dir> -> profile name for that directory.
# Order: $AI_BOX_KEY_PROFILE, .ai-profile in the directory, a pin under
# ~/.aikeys/projects/, a profile named after the directory, then "default".
# See docs/credentials.md.
resolve_key_profile() {
    local dir="$1" base
    if [[ -n "${AI_BOX_KEY_PROFILE:-}" ]]; then printf '%s' "$AI_BOX_KEY_PROFILE"; return; fi
    base="$(basename "$(cd "$dir" 2>/dev/null && pwd -P || echo "$dir")")"
    if [[ -r "$dir/.ai-profile" ]]; then
        grep -vE '^[[:space:]]*(#|$)' "$dir/.ai-profile" | head -1 | tr -d '\r\n'; return
    fi
    if [[ -r "$KEYS_DIR/projects/$base" ]]; then tr -d '\r\n' < "$KEYS_DIR/projects/$base"; return; fi
    if [[ -r "$KEYS_DIR/$base.key" ]]; then printf '%s' "$base"; return; fi
    printf 'default'
}

# key_profile_path <profile> -> the file that profile lives in
key_profile_path() { printf '%s/%s.key' "$KEYS_DIR" "$1"; }

# assert_profile_file_sane <project-dir>
# .ai-profile names a profile and is meant to be committed. If it holds a
# key instead, refuse rather than treating a secret as a filename -- and say so,
# because a committed file means the key has probably left the machine.
#
# Deliberately NOT folded into resolve_key_profile: that runs inside a command
# substitution, where die() would kill only the subshell and the caller would
# sail on. Call this first, in the parent shell.
assert_profile_file_sane() {
    local dir="$1" f declared
    f="$dir/.ai-profile"
    [[ -r "$f" ]] || return 0
    declared="$(grep -vE '^[[:space:]]*(#|$)' "$f" | head -1 | tr -d '\r\n')"
    # Any recognised credential shape, not only Anthropic's: since vendor keys
    # were added the guard protected sk-ant-* and silently let an xai-, sk-proj-
    # or AIza key through into a file designed to be committed.
    if [[ -n "$declared" ]] && [[ "$(aibox_key_kind_of_value "$declared")" != unknown ]]; then
        die ".ai-profile in $dir contains a credential, not a profile name.
       That file is meant to be committed, so treat the key as compromised:
       revoke it in the Console, then run  ai-keys add <profile>
       and put only the profile NAME in .ai-profile"
    fi
}

# safe_hostname <image-key> -- an RFC-1123 label derived from the image.
#
# The image reference carries ':' (tag separator) and '.' (version dots), and
# neither belongs in a hostname label. ':' is not a legal hostname character,
# and '.' would make bash's \h truncate the prompt at the first dot, so
# "ai-fedora:44-cc2.1.211" used to show as "ai-box-ai-fedora" and
# told you nothing about which build you were in. Both become '-' so the tag
# stays visible.
#
# The hard constraint is length, not charset: the kernel's sethostname() caps a
# label at 64 bytes and Docker surfaces the overflow as
# "sethostname: invalid argument", so cap at 63 and never end on a hyphen.
safe_hostname() {
    local raw="ai-box-$1" out
    out="$(printf '%s' "$raw" \
        | tr -c 'a-zA-Z0-9' '-' \
        | tr -s '-' \
        | cut -c1-63)"
    out="${out%%-}"
    printf '%s' "${out:-ai-box}"
}

# json_ok <file> -- is this parseable JSON? Prefers a real parser, degrades to a
# heuristic rather than assuming python3 or jq is installed on the host.
json_ok() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null && return 0 || return 1
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$f" >/dev/null 2>&1 && return 0 || return 1
    fi
    # No parser available: catch the failure mode that actually occurs here, an
    # empty or truncated file, and let anything else through.
    local first last
    first="$(head -c 1 "$f")"
    last="$(tail -c 2 "$f" | tr -d '\n')"
    [[ "$first" == "{" && "$last" == *"}" ]]
}



# ---- engine diagnosis --------------------------------------------------------
# `need docker` reports a missing binary. It does not distinguish that from a
# daemon that is not running or a user who is not in the docker group, and those
# three have different fixes. This does.
engine_usable() { command -v "$1" >/dev/null 2>&1 && "$1" info >/dev/null 2>&1; }

# require_engine -- usable engine, or an explanation and a way forward.
require_engine() {
    engine_usable "$ENGINE" && return 0

    local why err
    if ! command -v "$ENGINE" >/dev/null 2>&1; then
        why="not installed"
    else
        err="$("$ENGINE" info 2>&1 || true)"
        case "$err" in
            *"Cannot connect to the Docker daemon"*|*"docker daemon is not running"*|*"connection refused"*)
                why="installed, but the daemon is not running" ;;
            *"permission denied"*)
                why="running, but this user cannot reach its socket" ;;
            *) why="present but not usable" ;;
        esac
    fi

    printf '\033[1;31merror:\033[0m container engine (%s) is %s\n' "$ENGINE" "$why" >&2

    case "$why" in
        *"daemon is not running"*)
            printf '       start it:  sudo systemctl start docker\n' >&2
            printf '       at boot:   sudo systemctl enable --now docker\n' >&2 ;;
        *"cannot reach its socket"*)
            printf '       add yourself to the group, then log out and back in:\n' >&2
            printf '         sudo usermod -aG docker "$USER"\n' >&2
            printf '       note that docker group membership is equivalent to host root.\n' >&2 ;;
        *"not installed"*)
            printf '       install Docker Engine, or use Podman (below).\n' >&2 ;;
    esac

    # Podman is a genuine alternative here, but not a drop-in: it keeps images in
    # its own store, so an image built by Docker is not visible to it. Say that,
    # rather than suggesting a switch that would report "image not built".
    if [[ "$ENGINE" != podman ]] && command -v podman >/dev/null 2>&1; then
        printf '\n       Podman is installed and usable. It is supported here:\n' >&2
        printf '         AI_BOX_ENGINE=podman %s ...\n' "$(basename "$0")" >&2
        printf '       Podman keeps images in its own store, so images built with\n' >&2
        printf '       Docker are not visible to it. Either rebuild:\n' >&2
        printf '         AI_BOX_ENGINE=podman ai-box-build all\n' >&2
        printf '       or, while the Docker daemon is reachable, copy them across:\n' >&2
        for k in "${ALL_IMAGE_KEYS[@]}"; do
            printf '         podman pull docker-daemon:%s\n' "$(image_ref "$k")" >&2
        done
    fi
    exit 1
}
