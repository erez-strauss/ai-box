#!/usr/bin/env bash
# Put ai-box and the helper scripts on PATH and create the host directories.
# Re-run this from a newer package to switch over; it only replaces symlinks.
set -euo pipefail
# shellcheck source=lib-common.sh
source "$(dirname "$(readlink -f "$0")")/lib-common.sh"

BIN="${AI_BOX_BIN:-$HOME/.local/bin}"
mkdir -p "$BIN" "$CONFIG_ROOT" "$STATE_ROOT"
chmod 700 "$CONFIG_ROOT"
chmod 700 "$STATE_ROOT"

# Every executable script in scripts/ is linked, discovered rather than listed.
# A hand-maintained list drifted silently: capabilities.sh, doctor.sh, migrate.sh
# and the four check-* scripts were all added to the package and never linked,
# because each edit to the list matched a slightly different wrapping and did
# nothing. Discovery cannot drift.
#
# Excluded, with reasons: lib-common.sh is sourced, never run; legacy-shim.sh is
# linked below under its old names; install.sh and pack.sh are maintainer
# commands run from the package root.
NOT_LINKED=(lib-common.sh install.sh pack.sh)

for target in "$PKG_ROOT"/scripts/*; do
    [[ -f "$target" && -x "$target" ]] || continue
    s="$(basename "$target")"
    skip=0
    for n in "${NOT_LINKED[@]}"; do [[ "$s" == "$n" ]] && skip=1; done
    (( skip )) && continue

    # ai-box and ai-keys keep their own names; everything else becomes
    # ai-box-<name>, so `ai-box-capabilities` rather than `capabilities`.
    if [[ "$s" == ai-box || "$s" == ai-keys ]]; then
        link="$BIN/$s"
    else
        link="$BIN/ai-box-${s%.sh}"
    fi
    ln -sfn "$target" "$link"
    log "linked $link -> $target"
done

if [[ ! -d "$KEYS_DIR" ]]; then
    mkdir -p "$KEYS_DIR/projects"
    chmod 700 "$KEYS_DIR" "$KEYS_DIR/projects"
    log "created key store $KEYS_DIR - add a key with: ai-keys add default"
fi

# Deliberately does NOT create ~/.config/ai-box/anthropic.env. Seeding it
# from the example put a placeholder that looks like a secret on disk, and left
# `-a envfile` failing against "sk-ant-api03-REPLACE-ME" rather than saying the
# file was never configured. The env-file path is legacy anyway; the key store
# keeps the credential out of `docker inspect`.
if [[ ! -e "$CONFIG_ROOT/anthropic.env" ]]; then
    log "no $CONFIG_ROOT/anthropic.env (only needed for -a envfile; prefer: ai-keys add default)"
fi

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) warn "$BIN is not on PATH; add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

log "ai-box $PKG_VERSION installed. Next: scripts/build.sh all"
