#!/usr/bin/env bash
# The mount guard, exercised through `ai-box -n` rather than by re-implementing
# its logic. Every case here comes from a review that found the guard was an
# exact match: /etc was refused while /etc/ssh, /var/log, /root/.ssh and /tmp
# were all accepted.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/_harness.sh"

HOME="$(mktemp -d)"; export HOME
export AI_BOX_STATE="$HOME/state" AI_BOX_CONFIG="$HOME/cfg" AI_KEYS_DIR="$HOME/.aikeys"
STUB="$(mktemp -d)"; printf '#!/bin/sh\ncase "$1" in image) exit 0;; volume) exit 1;; info) exit 0;; run) shift; echo "$*";; *) exit 0;; esac\n' > "$STUB/docker"
chmod +x "$STUB/docker"; PATH="$STUB:$PATH"; export PATH
trap 'rm -rf "$HOME" "$STUB"' EXIT

# A refusal must come from the guard, not from the directory being absent.
#
# The first version of these helpers treated any non-zero exit as a pass, so a
# case naming a path that does not exist passed for the wrong reason, and the
# one case expecting success failed on a CI runner where an unprivileged user
# cannot create a directory under /home. Match the message instead.
refuses() {  # refuses <label> <dir>
    local out
    # No mkdir. The guard judges the path before checking that it exists, so a
    # refusal does not depend on the test being able to create anything -- which
    # it could not for /opt/foo or /root on an unprivileged runner.
    out="$("$HERE/../scripts/ai-box" -n -p "$2" -a none -- true 2>&1 >/dev/null || true)"
    case "$out" in
        *"refusing to mount"*)  ok "$1" ;;
        *"no such directory"*)  fail "$1" "refused by the guard" "the directory does not exist, so the guard was never reached" ;;
        '')                     fail "$1" "refused by the guard" "allowed" ;;
        *)                      fail "$1" "refused by the guard" "$out" ;;
    esac
}

allows() {   # allows <label> <dir>
    local out
    if ! mkdir -p "$2" 2>/dev/null; then
        fail "$1" "a usable directory" "could not create $2 in this environment"
        return
    fi
    out="$("$HERE/../scripts/ai-box" -n -p "$2" -a none -- true 2>&1 >/dev/null || true)"
    if [[ -z "$out" ]]; then ok "$1"; else fail "$1" "allowed" "$out"; fi
}

for d in /etc /var /root /usr /opt /boot /proc /sys /dev /srv /mnt /media; do
    refuses "system tree $d" "$d"
done
# /tmp is refused as itself but not by prefix: mounting all of /tmp hands over
# every host socket and scratch secret, while a directory under it is an
# ordinary scratch project -- and the package's own probes live there.
refuses "the whole temp directory" /tmp
refuses "the whole var temp"       /var/tmp
# The whole point: prefix, not exact.
# None of these need to exist, which is the point: the guard is about the path,
# not about the filesystem. /opt/foo and /root/.ssh are unreachable for an
# unprivileged user and are checked anyway.
for d in /etc/ssh /var/log /usr/local/src /opt/foo /root/.ssh /boot/efi; do
    refuses "beneath a system tree: $d" "$d"
done
allows "a scratch project under /tmp" "/tmp/ai-box-scratch-test"
refuses "the home directory itself" "$HOME"
refuses "/"                          "/"
refuses "/home"                      "/home"
for s in .ssh .gnupg .aws .kube .docker .config .local .password-store; do
    refuses "credential dir $s" "$HOME/$s"
done
refuses "the key store"   "$AI_KEYS_DIR"
refuses "the state root"  "$AI_BOX_STATE"

# A symlinked store must be refused by its resolved path too: PROJECT_DIR is
# canonicalised with `pwd -P`, so comparing against an unresolved target let
# `-p /real/path` through when ~/.aikeys pointed at it.
real="$(mktemp -d)"; rm -rf "$AI_KEYS_DIR"; ln -sfn "$real" "$AI_KEYS_DIR"
refuses "the key store through its symlink target" "$real"
rm -rf "$AI_KEYS_DIR"; mkdir -p "$AI_KEYS_DIR"

allows "an ordinary project"            "$HOME/src/proj"

# The guard refuses /home itself and $HOME itself, both exactly, because projects
# live under them. A sibling home must still be allowed. Rooted in the temp tree
# rather than the real /home: an unprivileged CI runner cannot create a directory
# there, and the assertion is about the guard, not about filesystem permissions.
mkdir -p "$HOME/../home-of-someone-else/proj"
allows "a sibling user's project"       "$HOME/../home-of-someone-else/proj"
finish
