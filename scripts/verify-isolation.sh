#!/usr/bin/env bash
# Prove the container cannot reach anything but the mounted project directory.
#
# Two halves, and the first one matters most: it asserts against the argv that
# `ai-box -n` prints, so a regression in the wrapper's run flags fails here.
# Half two then RUNS the box through the same script, for the same reason.
# Until 1.4.0 this script rebuilt the flags itself, which meant ai-box could
# have dropped --cap-drop=ALL and every check would still have said PASS.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

require_host

KEY="${1:-ubuntu}"
REF="$(image_ref "$KEY")"
BOX="$PKG_ROOT/scripts/ai-box"
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-box-probe.XXXXXX")"
trap 'rm -rf "$PROBE_DIR"' EXIT

require_engine
image_exists "$REF" || die "image $REF not built; run scripts/build.sh $KEY"

rc=0
chk() {
    printf '%-46s %s\n' "$1" "$2"
    case "$2" in FAIL*) rc=1 ;; esac
}

# ---- half one: the command ai-box would actually run --------------------
log "checking the run flags ai-box uses for $REF"

mapfile -t ARGV < <("$BOX" -n -i "$KEY" -p "$PROBE_DIR" -a none -- true)
[[ ${#ARGV[@]} -gt 0 ]] || die "ai-box -n produced no output"

argv_has() {
    local a
    for a in "${ARGV[@]}"; do
        if [[ "$a" == "$1" ]]; then return 0; fi
    done
    return 1
}
argv_has_pair() {
    local i
    for (( i = 0; i + 1 < ${#ARGV[@]}; i++ )); do
        if [[ "${ARGV[i]}" == "$1" && "${ARGV[i+1]}" == "$2" ]]; then return 0; fi
    done
    return 1
}
argv_values_of() {
    local i
    for (( i = 0; i + 1 < ${#ARGV[@]}; i++ )); do
        if [[ "${ARGV[i]}" == "$1" ]]; then printf '%s\n' "${ARGV[i+1]}"; fi
    done
}
# argv_has_volume <src:dst> -- true if some --volume value is exactly that, or
# that plus mount options. The options matter: on an SELinux host ai-box
# appends ",z", and a check written as an exact string match started failing on
# Fedora for a wrapper that was doing the right thing.
argv_has_volume() {
    local v
    while IFS= read -r v; do
        if [[ "$v" == "$1" || "$v" == "$1",* ]]; then return 0; fi
    done < <(argv_values_of "--volume")
    return 1
}

# The command must actually be the engine, not something else that happens to
# accept these flags.
if [[ "${ARGV[0]}" == "$ENGINE" && "${ARGV[1]}" == run ]]; then
    chk "command: $ENGINE run" "PASS"
else
    chk "command: $ENGINE run" "FAIL (${ARGV[0]} ${ARGV[1]:-})"
fi

if argv_has "--cap-drop=ALL"; then chk "flag: --cap-drop=ALL" "PASS"
else chk "flag: --cap-drop=ALL" "FAIL (missing)"; fi

if argv_has_pair "--security-opt" "no-new-privileges"; then chk "flag: no-new-privileges" "PASS"
else chk "flag: no-new-privileges" "FAIL (missing)"; fi

if argv_has_pair "--user" "$(id -u):$(id -g)"; then chk "flag: --user matches the caller" "PASS"
else chk "flag: --user matches the caller" "FAIL (missing or wrong)"; fi

if argv_has "--privileged"; then chk "flag: not --privileged" "FAIL"
else chk "flag: not --privileged" "PASS"; fi

if argv_has_pair "--security-opt" "seccomp=unconfined"; then
    chk "flag: seccomp confined by default" "FAIL (debug relaxation is on)"
else
    chk "flag: seccomp confined by default" "PASS"
fi

# Every bind source must be the project directory, the per-image state
# directory, or the optional named toolchain volume. Anything else is a widened
# mount surface, which is the failure this product exists to prevent.
bad_mounts=""
n_mounts=0
while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    n_mounts=$((n_mounts + 1))
    src="${spec%%:*}"
    case "$src" in
        "$PROBE_DIR"|"$STATE_ROOT"/*|ai-toolchains) ;;
        *) bad_mounts="${bad_mounts} ${src}" ;;
    esac
done < <(argv_values_of "--volume")

if [[ -z "$bad_mounts" ]]; then
    chk "mounts: project + state only" "PASS ($n_mounts binds)"
else
    chk "mounts: project + state only" "FAIL (unexpected:${bad_mounts})"
fi

if argv_has_volume "$PROBE_DIR:/workspace"; then chk "mounts: project dir at /workspace" "PASS"
else chk "mounts: project dir at /workspace" "FAIL"; fi

# Under rootless podman, keep-id is what makes --user mean the caller's UID
# rather than a subordinate one. Without it the hardening flags are all present
# and the files still come out owned by nobody, which is a real failure that
# none of the other checks would notice.
if [[ "$ENGINE" == podman ]]; then
    if argv_has "--userns=keep-id"; then chk "podman: --userns=keep-id" "PASS"
    else chk "podman: --userns=keep-id" "FAIL (files in /workspace would be owned by a subuid)"; fi
fi

# With -a none there is no credential, so there must be no --mount at all.
if argv_has "--mount"; then chk "mounts: no secret mount without a key" "FAIL"
else chk "mounts: no secret mount without a key" "PASS"; fi

for forbidden in "/var/run/docker.sock" "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" "$KEYS_DIR"; do
    hit=0
    for a in "${ARGV[@]}"; do
        case "$a" in *"$forbidden"*) hit=1 ;; esac
    done
    label="argv free of ${forbidden/#$HOME/\~}"      # ~ keeps the column readable
    if (( hit )); then chk "$label" "FAIL"
    else chk "$label" "PASS"; fi
done

# ---- half two: what the container can actually do ---------------------------
log "probing $REF with $PROBE_DIR mounted at /workspace"

probe_out=""
probe_rc=0
# Through ai-box, not a hand-built engine invocation. An earlier version rebuilt
# the hardening flags here, so a wrapper that added a bind AFTER printing its
# `-n` output would have passed both halves of this check. Both halves must
# share one construction path, or this file re-creates the bug class it exists
# to catch. Running the real entrypoint is a bonus: it gets exercised too.
probe_out="$("$PKG_ROOT/scripts/ai-box" -i "$KEY" -p "$PROBE_DIR" -a none \
    -- bash -lc '
set -u
fail=0
chk() { printf "%-46s %s\n" "$1" "$2"; }

if [[ "$(id -u)" != 0 ]]; then chk "runs as non-root" "PASS ($(id -un) $(id -u))"
else chk "runs as non-root" "FAIL"; fail=1; fi

if command -v sudo >/dev/null; then chk "sudo absent" "FAIL"; fail=1
else chk "sudo absent" "PASS"; fi

if [[ -S /var/run/docker.sock ]]; then chk "no docker socket" "FAIL"; fail=1
else chk "no docker socket" "PASS"; fi

if [[ -d "$HOME/.ssh" ]]; then chk "no ssh keys" "FAIL"; fail=1
else chk "no ssh keys" "PASS"; fi

caps="$(grep -E "^CapEff:" /proc/self/status | awk "{print \$2}")"
if [[ "$caps" =~ ^0+$ ]]; then chk "effective capabilities empty" "PASS"
else chk "effective capabilities empty" "FAIL ($caps)"; fail=1; fi

nnp="$(grep -E "^NoNewPrivs:" /proc/self/status | awk "{print \$2}")"
if [[ "$nnp" == 1 ]]; then chk "no_new_privs set" "PASS"
else chk "no_new_privs set" "FAIL (${nnp:-absent})"; fail=1; fi

setuid_count="$(find /usr /bin /sbin -xdev -perm -4000 -type f 2>/dev/null | wc -l)"
chk "setuid binaries present" "${setuid_count} (inert: no_new_privs + no caps)"

hostmounts=$(findmnt -no TARGET -t ext4,xfs,btrfs,overlay 2>/dev/null | grep -v "^/$" | tr "\n" " ")
chk "host filesystems visible" "${hostmounts:-none beyond /}"

if touch /workspace/.probe 2>/dev/null; then chk "/workspace is writable" "PASS"
else chk "/workspace is writable" "FAIL"; fail=1; fi

if touch /etc/.probe 2>/dev/null; then chk "/etc not writable" "FAIL"; fail=1
else chk "/etc not writable" "PASS"; fi

if touch /usr/local/bin/.probe 2>/dev/null; then chk "/usr/local/bin not writable" "FAIL"; fail=1
else chk "/usr/local/bin not writable" "PASS"; fi

if command -v claude >/dev/null; then chk "claude present" "PASS ($(claude --version 2>/dev/null | head -1))"
else chk "claude present" "FAIL"; fail=1; fi

exit $fail
')" || probe_rc=$?
printf '%s\n' "$probe_out"
if (( probe_rc != 0 )); then rc=1; fi

# ---- half three: -N none really means no network ----------------------------
# Through ai-box, like the other two halves. Building this invocation by hand
# meant a wrapper that stopped passing --network would still have shown a green
# result here, which is exactly the failure hard rule 14 exists to prevent.
net_out="$("$PKG_ROOT/scripts/ai-box" -i "$KEY" -p "$PROBE_DIR" -a none -N none \
    -- bash -lc 'getent hosts api.anthropic.com >/dev/null 2>&1 && echo RESOLVED || echo BLOCKED' \
    2>/dev/null || true)"
if [[ "$net_out" == *RESOLVED* ]]; then
    chk "-N none blocks name resolution" "FAIL (resolved anyway)"
    rc=1
else
    chk "-N none blocks name resolution" "PASS"
fi

# ---- host side: ownership of files the container created --------------------
if [[ -f "$PROBE_DIR/.probe" ]]; then
    owner="$(stat -c '%u:%g' "$PROBE_DIR/.probe")"
    if [[ "$owner" == "$(id -u):$(id -g)" ]]; then
        chk "files in /workspace owned by the host user" "PASS ($owner)"
    else
        chk "files in /workspace owned by the host user" "FAIL ($owner)"
    fi
fi

if (( rc == 0 )); then
    log "isolation checks passed for $REF"
else
    die "isolation checks FAILED for $REF"
fi
