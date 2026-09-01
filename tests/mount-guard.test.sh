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

refuses() {  # refuses <label> <dir>
    mkdir -p "$2" 2>/dev/null || true
    if "$HERE/../scripts/ai-box" -n -p "$2" -a none -- true >/dev/null 2>&1; then
        fail "$1" "refused" "allowed"
    else
        ok "$1"
    fi
}
allows() {
    mkdir -p "$2" 2>/dev/null || true
    if "$HERE/../scripts/ai-box" -n -p "$2" -a none -- true >/dev/null 2>&1; then
        ok "$1"
    else
        fail "$1" "allowed" "refused"
    fi
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
for d in /etc/ssh /var/log /usr/local/src /opt/foo; do
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
allows "another user home"              "/home/someone-else-proj"
finish
