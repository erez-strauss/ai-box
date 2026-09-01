# API keys without a browser

**Applies to:** ai-box v2.3.7

**Companions:** `docs/operating-guide.md` §4 (the older, briefer treatment),
`docs/upgrading.md`

The default `/login` flow opens a browser. In a container on a headless box, over SSH,
or in CI, that is either awkward or impossible. This document covers the alternatives,
where to put the credential, and why the obvious place is the wrong one.

---

## 0. Which credential can actually skip the browser

| Credential | Browser needed? | Billing | Get it from |
|---|---|---|---|
| **Console API key** (`sk-ant-api…`) | **No** | per-token API usage | platform.claude.com → API keys |
| **Long-lived OAuth token** (`claude setup-token`) | Once, on any machine | your Pro/Max/Team plan | run the command, approve in a browser, copy the token |
| Gateway bearer token | depends on your IdP | your gateway | your platform team |
| `/login` OAuth | Yes, every renewal | your plan | interactive |

Only the Console API key is browser-free end to end. `claude setup-token` still opens a
browser authorization flow, but it prints a one-year token you can carry to a machine
that has no browser at all - so "borrow a browser once, on your laptop" solves the
headless problem for subscription users. The token can only make model requests: it
cannot establish Remote Control sessions or fetch claude.ai connectors.

**Precedence matters.** When several credentials are present Claude Code picks in this
order: cloud provider credentials, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`,
`apiKeyHelper`, `CLAUDE_CODE_OAUTH_TOKEN`, then the stored `/login` credential. A
leftover `ANTHROPIC_API_KEY` in your environment silently outranks your subscription
login, which is a common and confusing way to get billed per token or to hit an error
about a disabled organization. Inside the box, `/status` shows which one is live.

---

## 1. Where the key goes: `~/.aikeys`

```
~/.aikeys/                 mode 0700
├── README                     what the format is
├── default.key                mode 0600
├── work.key
├── ci.key
├── work.env                   optional, NON-secret (base URL, model)
└── projects/
    └── myproject              contains a profile NAME, not a key
```

A key file is plain text with optional metadata:

```
# ai-box key profile: work
# added: 2026-08-03T14:02:11Z
kind: api
sk-ant-api03-<the key from the Console>
```

The placeholder above is written with an obvious angle-bracket stand-in rather
than a plausible-looking run of characters, because CI greps the repository for
credential-shaped strings and a realistic placeholder would fail the build. That
is the intended behaviour: a check that cannot tell a fake key from a real one
is the only kind that catches a real one.

The rules are exactly these, and one parser
(`shared/keyfile-lib.sh`) implements them for both the host scripts and the
container entrypoint:

- a line starting with `#` is a comment;
- a line of the form `name: value` is metadata, for `name` in `kind`, `added`,
  `note`, `label`, `profile`, `desc`, `comment`, `source`. The space after the
  colon is optional;
- the first line that is neither is the secret, taken whole;
- the secret may be written as `NAME=value`, but only for `NAME` in
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
  `ANTHROPIC_KEY`, `API_KEY`, `TOKEN`, `KEY`. Any other line keeps its `=`
  characters, so a base64-ish token is never truncated.

`kind:` decides which environment variable the container exports - `api` →
`ANTHROPIC_API_KEY`, `oauth` → `CLAUDE_CODE_OAUTH_TOKEN`, `bearer` →
`ANTHROPIC_AUTH_TOKEN`. Getting this wrong is the single most common failure: an OAuth
token sent as `X-Api-Key` returns 401 or 403 with no hint about why. `ai-keys` sets
it from the key prefix and lets you override it.

### Set one up

```bash
ai-keys init
ai-keys add default          # paste the key; input is hidden, not echoed
ai-keys list
ai-keys check                # permissions and shape, no network
ai-keys test                 # one live API call, prints only the status code
```

`ai-keys add` reads from the terminal with echo off, so the key never lands in your
shell history or in `ps` output. For scripted setup, pipe it: `ai-keys add ci < key.txt`.

`ai-keys list` shows a fingerprint (last four characters plus a short hash) rather
than the key, so you can tell two profiles apart in a screenshot without leaking either.

---

## 2. Per-project keys

The request "keys in the project directory" is usually really "a different key per
project" - separate billing per client, a restricted key for one repo, a Console key for
one project and a subscription for another. You can have that without putting a secret
in the project directory. A project resolves to a profile in this order:

1. `$AI_BOX_KEY_PROFILE`
2. `.ai-profile` in the project directory - contains a profile **name**, never a key
3. `~/.aikeys/projects/<dirname>`, set by `ai-keys link`
4. `~/.aikeys/<dirname>.key` - a profile named after the directory
5. `~/.aikeys/default.key`

```bash
cd ~/src/acme-trading
ai-keys add acme             # a key just for this client
ai-keys link acme            # pin the directory to it
ai-keys which                # confirm what will be used
ai-box -- claude             # picks it up with no extra flags
```

Or commit the selection to the repo, since it names a profile and reveals nothing:

```bash
echo acme > .ai-profile
git add .ai-profile
```

Anyone who clones the repo and has a profile called `acme` gets the right key; anyone
who does not gets a clear error naming the profile they need to create.

### Why not the actual key in the project directory

The project directory is bind-mounted **read-write** at `/workspace`. That is the one place
the agent can write, and the whole point of the sandbox is that a mistake there is
recoverable. A key file in it is:

- readable by the agent and by every process it spawns, including build scripts and
  anything pulled from npm, PyPI, or crates.io during a build;
- one `git add .` from a public repository, and one `docker cp` or tarball from a
  colleague's laptop;
- likely to end up in a stack trace, a log, or a pasted diff.

So `ai-box` refuses a key file located inside the mounted project directory and
tells you to move it. If you have a hard reason to override this, the escape hatch is to
mount the key yourself:

```bash
docker run --rm -it \
  --mount type=bind,src=/path/to/key,dst=/run/secrets/ai-key,ro \
  --env AI_BOX_KEY_VAR=ANTHROPIC_API_KEY \
  ... ai-ubuntu:26.04
```

and at minimum add it to `.gitignore` **before** creating it. Also add a
`.git/info/exclude` entry, since `.gitignore` itself is often committed and reviewed
while `info/exclude` is local and cannot be accidentally shared.

---

## 3. How the key reaches the container

`ai-box` bind-mounts the selected file read-only at `/run/secrets/ai-key` and
sets `AI_BOX_KEY_VAR`; the entrypoint reads the file and exports the right variable.

```bash
ai-box -- claude              # auto: resolve a profile, else fall back to login
ai-box -k work -- claude      # a specific profile
ai-box -k /abs/path/to.key -- claude
ai-box -a login -- claude     # ignore the store, do the browser flow
ai-box -a none -- make        # no credential at all
```

The mount matters. Anything passed with `-e` or `--env` is visible in `docker inspect`
and to anyone in the `docker` group; a mounted file is not. The value still appears in
the `claude` process environment **inside** the container, which is unavoidable and
irrelevant to host isolation.

Nothing about the key is written into an image layer, a build arg, or `docker history`.

### Non-secret settings that travel with a profile

`~/.aikeys/<profile>.env` is mounted alongside and sourced. Use it for routing, not
for secrets:

```bash
cat > ~/.aikeys/workspace.env <<'EOF'
ANTHROPIC_BASE_URL=https://llm-gateway.internal.example.com
ANTHROPIC_MODEL=claude-opus-4-5-20251101
EOF
chmod 600 ~/.aikeys/workspace.env
```

---

## 4. A long-lived OAuth token for subscription users

If you pay for Pro or Max, you do not want per-token API billing. Borrow a browser once:

```bash
# on any machine that has a browser (your laptop):
claude setup-token
# approve in the browser; the token prints to the terminal. It is not saved anywhere.
```

Then, on the headless machine:

```bash
ai-keys add work        # paste the sk-ant-oat… token
ai-keys list            # should show kind=oauth -> CLAUDE_CODE_OAUTH_TOKEN
```

The token lasts about a year. It authenticates as your subscription, so no per-token
bill. Two limits worth knowing: it cannot establish Remote Control sessions or fetch
claude.ai connectors, and **bare mode (`claude -p --bare`) does not read it** - scripts
using `--bare` need an API key or an `apiKeyHelper`.

Rotate before expiry by re-running `claude setup-token` and `ai-keys add work`.

---

## 5. Rotating credentials with `apiKeyHelper`

For a key that must not sit on disk - a vault-issued short-lived token - use
`apiKeyHelper` instead of a key file. It is a script Claude Code runs under `/bin/sh`
that prints a credential on stdout, called again after 5 minutes or on an HTTP 401.

Put the helper in the per-image state directory, which is mounted at `~/.claude`:

```bash
STATE=~/.local/share/ai-box/ai-ubuntu_26.04/claude
cat > "$STATE/key-helper.sh" <<'EOF'
#!/bin/sh
# Print a credential on stdout. Nothing else: stray output becomes the key.
exec cat /run/secrets/ai-key
EOF
chmod 700 "$STATE/key-helper.sh"

cat > "$STATE/settings.json" <<'EOF'
{ "apiKeyHelper": "/home/dev/.claude/key-helper.sh" }
EOF
```

Tune the refresh with `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`. Two operational notes: a
helper that takes more than 10 seconds shows a warning in the prompt bar, and a helper
that errors, times out, or prints nothing fails the request with
`Your apiKeyHelper script is failing` after three attempts (older versions surfaced a
bare 401 after roughly ten silent retries, which was much harder to diagnose).

For a real vault, replace the `cat` with your CLI - but remember the container has no
host credentials, so the vault CLI needs its own bootstrap token, which puts you back
where you started unless the vault authenticates by workload identity.

---

## 6. Where Claude Code keeps its own credentials

After a `/login`, the credential is written on Linux to `~/.claude/.credentials.json`,
mode 0600 - inside the container, that is the per-image state directory on your host:

```
~/.local/share/ai-box/ai-ubuntu_26.04/claude/.credentials.json
```

It never touches your host `~/.claude`, so a host-side Claude Code install stays
independent. `CLAUDE_CONFIG_DIR` relocates it if you want that. Back it up like any
other secret, or just re-run `/login`. To revoke, delete the file, or use `/logout`
inside the container - note that logging out also resets first-launch setup, so the next
start walks through onboarding again.

---

## 7. CI and unattended runs

```bash
# GitHub Actions, GitLab CI, Jenkins: the key comes from the CI secret store
mkdir -p "$RUNNER_TEMP/keys" && chmod 700 "$RUNNER_TEMP/keys"
printf '%s' "$ANTHROPIC_API_KEY" > "$RUNNER_TEMP/keys/ci.key"
chmod 600 "$RUNNER_TEMP/keys/ci.key"

AI_KEYS_DIR="$RUNNER_TEMP/keys" \
  ai-box -k ci -p "$GITHUB_WORKSPACE" -- \
  claude -p --dangerously-skip-permissions "run the test suite and fix failures"
```

Use an API key rather than an OAuth token for CI: predictable billing, no yearly expiry
in the middle of a release, and `--bare` works. Scope it to a dedicated Console
workspace so you can revoke it without touching anything else.

---

## 8. Troubleshooting

| Symptom | Cause |
|---|---|
| Interactive `claude` still asks you to approve a key | Expected with `ANTHROPIC_API_KEY` set: you approve once and the choice is remembered. Change it later via the "Use custom API key" toggle in `/config`. |
| Billed per token despite a Pro plan | An `ANTHROPIC_API_KEY` outranks your login. Use an `oauth`-kind profile, or `ai-box -a login`. Check with `/status`. |
| 401 with a token that works elsewhere | Wrong `kind:` - an OAuth token sent as `X-Api-Key`. `ai-keys check <profile>` shows which variable it maps to. |
| 403 authenticated but refused | Org policy (`forceLoginMethod` / `forceLoginOrgUUID` block environment credentials), or an OAuth token used where an API key is required. |
| `claude -p --bare` reports "Not logged in" | Bare mode ignores `CLAUDE_CODE_OAUTH_TOKEN`. Use an API key or `apiKeyHelper`. |
| `ai-box` refuses the key file | It is inside the mounted project directory. See §2. |
| 401 from a profile that `ai-keys check` says is fine | Two parser bugs this package has since fixed: a `kind:` line written without a space after the colon was exported as the credential, and a secret containing `=` was truncated at the first one. Upgrade, or rewrite the profile with `ai-keys add`. |
| `Your apiKeyHelper script is failing` | The helper errored, timed out, or printed nothing. Run it by hand and confirm it prints exactly the credential on stdout. |
| Key works on the host, not in the box | The container has no host home. Confirm the mount: `ai-box -- ls -l /run/secrets/`. |
| `Login expired · Please run /login` | A stored `/login` credential aged out. Renew, or move to a key profile so unattended runs stop depending on it. |

Useful checks, none of which print the secret:

```bash
ai-keys check work
ai-keys test work                      # one request, status code only
ai-box -- bash -lc 'ls -l /run/secrets/; echo "${ANTHROPIC_API_KEY:+API key set}"'
ai-box -- claude doctor
```

---

## 9. Hygiene

- `~/.aikeys` is 0700, every key file 0600. `ai-keys check` verifies both.
- Never pass a key on a command line: it lands in shell history and in `ps` output for
  every user on the box. `ai-keys add` reads from the terminal with echo off.
- Rotate from the Console; `ai-keys add <profile>` overwrites in place, and the next
  container run picks up the new value with no rebuild.
- `ai-keys rm` shreds the file where the filesystem supports it.
- If `$HOME` is not encrypted, keep the key in `pass` instead and use `ai-box -a pass`,
  which stages it on `/dev/shm` and shreds it when the container exits. Set
  `AI_BOX_PASS_KIND=oauth|bearer` if the `pass` entry is not an API key: the staged
  file carries no `kind:` line, so the kind is otherwise guessed from the value.
- `ai-keys test` sends the credential in a curl config file, never as an argument, so
  it does not appear in `ps` while the request is in flight.
- A key that ever reached a repository, a CI log, or a chat message is burned. Revoke it
  in the Console; rewriting history does not un-leak it.
