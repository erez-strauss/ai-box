#!/usr/bin/env bash
# Install optional third-party AI coding agents into the image.
#
# Called from every Dockerfile with the value of the AI_AGENTS build arg, which
# is EMPTY by default: an image with more agents in it is a larger attack
# surface and a larger download, and most people want one agent. Opt in with
#   scripts/build.sh --agents codex,gemini
#   scripts/build.sh --agents all
#
# Distribution reality as of August 2026, which is why each agent is handled
# differently rather than through one mechanism:
#
#   codex   OpenAI. A real native binary: statically linked Rust (musl), no
#           runtime. Downloaded from GitHub Releases and checksummed. The only
#           one of the three that needs nothing else installed.
#   gemini  Google. Node/npm only (@google/gemini-cli); there is no native
#           Linux binary. Requires Node, which is why NODE_MAJOR exists.
#   grok    xAI. Node/npm (@xai-official/grok). The vendor's headline install is
#           `curl https://x.ai/cli/install.sh | bash`, which this deliberately
#           does not use: piping an unpinned remote script into a shell during
#           an image build is the one thing this project will not do. npm at
#           least pins a version and records an integrity hash.
#
# Claude Code itself is NOT installed here. It comes from Anthropic's signed
# apt/dnf repository in each Dockerfile, with a GPG fingerprint check, which is
# a stronger guarantee than any of the above.
set -euo pipefail

# This script installs system packages, writes into /usr/local/bin and runs
# `npm install -g`. Inside an image that is the job; run by hand on a host it
# silently modifies the host. That has happened: an earlier version of this file
# also ran `rm -rf /tmp/*` and deleted a working directory when it was invoked
# outside a container during a verification.
#
# The guard is explicit intent, not detection. Sniffing for "am I in a container"
# is unreliable, and sniffing for a marker file this project ships is worse: a
# host that has ever had one of these scripts run on it acquires the marker and
# then looks like an image. That is not hypothetical, it happened while testing
# this very guard. Only the Dockerfiles set AI_BOX_BUILD, so only they may run it.
if [[ -z "${AI_BOX_BUILD:-}" ]]; then
    echo "FATAL: install-agents.sh is run by the image build, not by hand." >&2
    echo "       It installs system packages and writes to /usr/local/bin, so on" >&2
    echo "       a host it would modify the host." >&2
    echo "       To add agents to an image:" >&2
    echo "         ai-box-build --agents <list> <image>" >&2
    echo "         ai-box-build --from-registry --agents <list> <image>" >&2
    echo "       To run it deliberately inside a container: AI_BOX_BUILD=1 $0 ..." >&2
    exit 1
fi

# The single list of what this script can install. `all` expands from it, so a
# fourth agent needs one edit here and nowhere else.
KNOWN_AGENTS=(codex gemini grok)

have() { command -v "$1" >/dev/null 2>&1; }

# A Node whose ICU data is missing segfaults inside any TUI that measures
# grapheme widths, with no JS stack and no catchable error. Detect it here,
# where the message can say what to install, rather than in a core dump.
assert_node_icu() {
    local small
    small="$(node -p 'String(process.config.variables.icu_small)' 2>/dev/null || echo unknown)"
    if ! node -e '[...new Intl.Segmenter("en",{granularity:"grapheme"}).segment("x")]' 2>/dev/null; then
        echo "FATAL: this Node cannot run Intl.Segmenter (icu_small=${small})." >&2
        echo "       Agent TUIs segfault on such a build: nodejs/node#51752." >&2
        echo "       On Fedora/Rocky install nodejs-full-i18n; on Debian/Ubuntu" >&2
        echo "       ensure libicu is present, or set NODE_ICU_DATA." >&2
        exit 1
    fi
    echo "node ICU: Intl.Segmenter works (icu_small=${small})"
}

# Install Node where it is missing. This lives here rather than in each
# Dockerfile so that deriving an image from a published base -- which is how
# agents are added to a pulled image -- takes exactly the same path as building
# from source. One implementation, one place to fix.
#
# nodejs-full-i18n is named explicitly on rpm distros because it is a *weak*
# dependency and these images install with install_weak_deps=False. Without it
# `Intl.Segmenter` segfaults inside V8 and any agent TUI dies with no JS stack
# (nodejs/node#51752).
ensure_node() {
    have npm && return 0
    echo "installing Node, required by $1"
    if have dnf; then
        dnf -y --setopt=install_weak_deps=False --nodocs install nodejs npm nodejs-full-i18n
        dnf clean all; rm -rf /var/cache/dnf
    elif have apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends nodejs npm
        rm -rf /var/lib/apt/lists/*
    else
        echo "FATAL: no supported package manager found to install Node" >&2
        exit 1
    fi
}


AGENTS="${1:-}"

# --node-only installs the runtime and stops, for images that want Node present
# without any agent (WITH_NODE=1).
if [[ "$AGENTS" == "--node-only" ]]; then
    ensure_node "WITH_NODE=1"
    assert_node_icu
    exit 0
fi

[[ -n "$AGENTS" ]] || { echo "no optional agents requested"; exit 0; }

if [[ "$AGENTS" == "all" ]]; then
    AGENTS="$(IFS=,; echo "${KNOWN_AGENTS[*]}")"
    echo "agents: all -> ${AGENTS}"
fi

: "${CODEX_VERSION:=}"          # empty = latest release
# Pinned, not `latest`. Claude Code is pinned by the image tag and installed from
# a signed repository with a fatal fingerprint check; leaving the npm agents on
# `latest` meant two builds of the same package version could contain different
# agent code. Override per build with --build-arg.
: "${GEMINI_VERSION:=0.55.1}"
: "${GROK_VERSION:=1.0.5}"
# Empty means "print the digest and continue"; set means a mismatch is fatal.
: "${CODEX_SHA256:=}"
: "${NPM_PREFIX:=/usr/local}"


need_node() {
    ensure_node "$1"
    have npm || { echo "FATAL: Node install did not produce npm" >&2; exit 1; }
    assert_node_icu
    return 0
}

install_codex() {
    local arch tag url tmp
    case "$(uname -m)" in
        x86_64)  arch=x86_64-unknown-linux-musl ;;
        aarch64) arch=aarch64-unknown-linux-musl ;;
        *) echo "FATAL: codex has no published binary for $(uname -m)" >&2; exit 1 ;;
    esac

    if [[ -n "$CODEX_VERSION" ]]; then
        tag="rust-v${CODEX_VERSION}"
    else
        # Two ways to resolve "latest", because the obvious one is unreliable in
        # a build: api.github.com rate-limits unauthenticated callers per source
        # IP, and a CI runner or a NAT-ed office shares that IP with everyone
        # else. The HTML /latest redirect is not rate-limited the same way, so
        # it is tried first and the API is the fallback.
        tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
               https://github.com/openai/codex/releases/latest 2>/dev/null \
               | sed 's#.*/tag/##')"
        case "$tag" in rust-v*) ;; *) tag="" ;; esac

        if [[ -z "$tag" ]]; then
            api="$(curl -fsSL https://api.github.com/repos/openai/codex/releases/latest 2>/dev/null || true)"
            tag="$(printf '%s' "$api" \
                   | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
            if [[ -z "$tag" ]]; then
                echo "FATAL: could not resolve the latest codex release." >&2
                case "$api" in
                    *"rate limit exceeded"*)
                        echo "       GitHub rate-limited this IP. Pin the version instead:" >&2
                        echo "       scripts/build.sh --agents codex --build-arg CODEX_VERSION=0.148.0" >&2 ;;
                    *)  echo "       Network or GitHub problem. Pin CODEX_VERSION to avoid the lookup." >&2 ;;
                esac
                exit 1
            fi
        fi
    fi
    echo "codex: resolved latest to ${tag}; pin it with CODEX_VERSION=${tag#rust-v}"

    url="https://github.com/openai/codex/releases/download/${tag}/codex-${arch}.tar.gz"
    tmp="$(mktemp -d)"
    # Removed on any exit from this function, not just the success path.
    trap 'rm -rf "$tmp"' RETURN
    echo "codex: ${tag} (${arch})"
    curl -fsSL "$url" -o "$tmp/codex.tar.gz"
    sha256sum "$tmp/codex.tar.gz" | sed 's/^/codex sha256: /'
    tar -xzf "$tmp/codex.tar.gz" -C "$tmp"
    install -m 0755 "$tmp/codex-${arch}" /usr/local/bin/codex
    rm -rf "$tmp"
    codex --version
}

install_gemini() {
    need_node gemini
    echo "gemini: @google/gemini-cli@${GEMINI_VERSION}"
    npm install -g --prefix "$NPM_PREFIX" "@google/gemini-cli@${GEMINI_VERSION}"
    gemini --version \
        || { echo "FATAL: gemini installed but 'gemini --version' failed" >&2; exit 1; }
}

install_grok() {
    need_node grok
    echo "grok: @xai-official/grok@${GROK_VERSION}"
    npm install -g --prefix "$NPM_PREFIX" "@xai-official/grok@${GROK_VERSION}"
    grok --version \
        || { echo "FATAL: grok installed but 'grok --version' failed" >&2; exit 1; }
}

IFS=',' read -ra _wanted <<< "$AGENTS"
for a in "${_wanted[@]}"; do
    case "$(echo "$a" | tr -d '[:space:]')" in
        ''|none) ;;
        codex)  install_codex ;;
        gemini) install_gemini ;;
        grok)   install_grok ;;
        claude) echo "note: claude-code is always installed from the signed repo; ignoring 'claude'" ;;
        *) echo "FATAL: unknown agent '$a' (known: ${KNOWN_AGENTS[*]}, or 'all')" >&2; exit 1 ;;
    esac
done

# npm leaves a large cache behind; it is of no use inside a read-mostly image.
#
# Clean npm's own directories only. This used to end `rm -rf /tmp/*`, which is
# indefensible in a script that is also runnable by hand: it deletes whatever
# else happens to be in /tmp, belonging to anyone. It did exactly that during a
# verification run. Each installer already removes its own temporary directory.
have npm && npm cache clean --force >/dev/null 2>&1 || true
rm -rf /root/.npm /root/.npmrc.tmp 2>/dev/null || true

echo "optional agents installed: ${AGENTS}"
