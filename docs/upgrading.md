# Upgrading Claude Code inside the images

**Applies to:** ai-box v2.3.9


## The model in one paragraph

Claude Code is installed from Anthropic's signed apt/dnf repositories, and both
images set `DISABLE_AUTOUPDATER=1`. Package-manager installs never auto-update, and
the container's root filesystem is thrown away on every `--rm`. So **the agent version
is a property of the image tag, exactly like the compiler version.** Upgrading means
rebuilding the image. That is a feature, not a limitation: `ai-ubuntu:26.04-cc2.1.211`
is a reproducible statement about which agent and which toolchain produced a build,
and nothing silently changes underneath a long-running session.

If you would rather have the agent update itself, see [Self-update mode](#alternative-self-update-mode) at the
end - it is supported, with tradeoffs.

---

## Routine upgrade

```bash
cd ~/src/ai-box-v2.3.9

scripts/check-updates.sh          # what is installed vs. what the channel offers
scripts/upgrade.sh                # rebuild all three images
scripts/verify-isolation.sh ubuntu
scripts/verify-isolation.sh fedora
```

Typical `check-updates.sh` output:

```
IMAGE                    INSTALLED          CANDIDATE          STATUS
ai-ubuntu:26.04      2.1.211            2.1.238-1          UPGRADE AVAILABLE
ai-fedora:44         2.1.211            2.1.238            UPGRADE AVAILABLE

Upstream latest release (npm dist-tag, for reference): 2.1.240
```

The check is read-only. It starts a throwaway `--user 0:0` container from each image,
refreshes only that container's package metadata, and asks the package manager what the
candidate version is. It does not modify the image, the state directory, or anything
running. The container runs with `no-new-privileges` and a pids limit but keeps its
capabilities: apt drops privileges to the `_apt` user to fetch, which needs
`CAP_SETUID`, and without it the query becomes unreliable. It mounts nothing.

### What `upgrade.sh` actually does

1. Retags the current image as `ai-ubuntu:26.04-prev` (rollback point).
2. Asks the channel, from inside the existing image, what version it offers right now,
   and passes it as `--build-arg CLAUDE_VERSION=…`. **Changing that build arg is what
   invalidates the Docker layer cache for the install step.** Without it Docker reuses
   the cached layer containing the old agent, and the upgrade installs nothing. Your own
   `-c` always wins over the resolved candidate; if the channel cannot be queried,
   `upgrade.sh` says so and falls back to `--no-cache`.
3. Rebuilds with `--pull` and OS updates on, so system packages get their pending
   security fixes too. An image that gets a new agent but keeps months-old system
   libraries has not really been upgraded. Pass `--no-updates` to move the agent alone.
4. Re-tags the result as `…-cc<new version>` and `…-pkg<package version>`.
5. Prints the before/after versions and the rollback commands.

Step 2 is why this works: the only thing that would otherwise bust the install layer is
the daily OS-update stamp. `upgrade.sh --no-updates` therefore installed nothing at all,
and a second upgrade on the same day did nothing either. Both reported "channel had
nothing newer", which was true of neither.

### Pinning an exact version

```bash
scripts/upgrade.sh -c 2.1.238            # all three images on exactly 2.1.238
scripts/upgrade.sh -c 2.1.238 ubuntu     # one image only
```

Pin when you need two machines to behave identically, when you are bisecting an
agent-behaviour regression, or when a release broke something for you.

### Agent only, or OS only

```bash
scripts/upgrade.sh --no-updates          # new Claude Code, OS packages untouched
scripts/build.sh all                     # OS updates without changing the pinned agent
scripts/upgrade.sh -t 26.04.1            # upgrade onto a specific base tag
```

### Fast path

`--pull` and a cold cache mean a full rebuild (several minutes, mostly LLVM). If you
only want the newer agent and do not care about base-OS package updates:

```bash
scripts/upgrade.sh -k            # keep the OS layer cache
```

`-k` implies `--no-updates` and says so when you pass it: the OS layers can only be
reused if nothing earlier in the Dockerfile changes, and applying OS updates
deliberately changes the very first one every day. The Claude Code layer is still
rebuilt, because the resolved candidate goes in as `CLAUDE_VERSION`. `upgrade.sh` still
warns when the installed version did not move.

### Channels: `stable` vs `latest`

The Dockerfiles default to the `stable` channel, which trails `latest` by roughly a
week and skips releases with known major regressions. To track releases as they ship:

```bash
scripts/build.sh -C latest all
```

Set it once per environment and stay consistent - mixing channels across images makes
"it works in the Fedora box" reports hard to interpret.

### Rollback

```bash
docker tag ai-ubuntu:26.04-prev ai-ubuntu:26.04
docker tag ai-fedora:44-prev    ai-fedora:44
```

Or go further back - every upgrade leaves a `…-cc<version>` tag behind:

```bash
docker images --filter=reference='ai-*'
docker tag ai-ubuntu:26.04-cc2.1.211 ai-ubuntu:26.04
```

### What survives an upgrade

| Survives | Does not survive |
|---|---|
| OAuth token, `~/.claude` sessions and settings (host state dir) | anything installed inside a running container |
| ccache (host state dir) | `/tmp` contents |
| custom toolchains in the `ai-toolchains` volume | the previous image layers, once pruned |
| the project itself (bind mount) | |

No credential is touched by a rebuild. You will not be asked to log in again.

---

## Automating the check

A user-level systemd timer that reports weekly without ever building anything on its
own:

`~/.config/systemd/user/ai-box-check.service`

```ini
[Unit]
Description=Check for a newer Claude Code in the ai-box images

[Service]
Type=oneshot
ExecStart=%h/src/ai-box-v2.3.9/scripts/check-updates.sh
StandardOutput=journal
```

`~/.config/systemd/user/ai-box-check.timer`

```ini
[Unit]
Description=Weekly ai-box update check

[Timer]
OnCalendar=Mon 09:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now ai-box-check.timer
journalctl --user -u ai-box-check.service -n 20
```

Deliberately *check*, not *upgrade*: an unattended rebuild that swaps the agent version
under you is the kind of surprise this whole setup exists to avoid. Run `upgrade.sh`
when you are ready for it, not while you are mid-session.

---

## Upgrading the base OS and the compilers

Same mechanism, different knob.

```bash
# make GCC 16 the unversioned compiler in the Ubuntu image
scripts/build.sh -g 16 ubuntu

# Clang newer than the Ubuntu archive's 21, from apt.llvm.org
scripts/build.sh -L -l 22 ubuntu

# next Ubuntu LTS: change the default in the Dockerfile, or just override it
docker build -f docker-ubuntu/Dockerfile.ai-ubuntu \
  --build-arg BASE_IMAGE=ubuntu:28.04 \
  --build-arg UID=$(id -u) --build-arg GID=$(id -g) \
  -t ai-ubuntu:28.04 .

# next Fedora: edit docker-fedora/Dockerfile.ai-fedora44 (FROM fedora:45)
AI_BOX_FEDORA_IMAGE=ai-fedora:45 scripts/build.sh fedora
```

Keep the old image around until the new one has built your project cleanly.

### Migrating state when the image tag changes

State directories are keyed by image reference, so `ai-ubuntu:26.04` gets
`~/.local/share/ai-box/ai-ubuntu_26.04/` and knows nothing about the old
`ai-ubuntu_24.04/`. For ccache that is exactly right: a different compiler should
start with a cold cache rather than reusing objects built by another one.

Your login is a different matter. Carry it across rather than re-authorizing:

```bash
OLD=~/.local/share/ai-box/ai-ubuntu_24.04
NEW=~/.local/share/ai-box/ai-ubuntu_26.04
mkdir -p "$NEW"
cp -a "$OLD/claude" "$NEW/"        # config, credentials, sessions, settings
```

Copy the `claude` directory only. Leave `ccache` behind and let it rebuild.

---

## Supply-chain notes

The Dockerfiles fetch Anthropic's release signing key and **fail the build** unless the
fingerprint is `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`. After that, apt and dnf verify
every package signature themselves. If Anthropic rotates the key, your build breaks loudly
rather than trusting a new key silently - verify the new fingerprint against
<https://code.claude.com/docs/en/setup> before editing the Dockerfile.

The default Ubuntu build trusts no third-party repository at all: every compiler comes
from Ubuntu's own archive. `apt.llvm.org` is reached only on the opt-in
`-L`/`LLVM_FROM_UPSTREAM=1` path, where its key is added by the upstream `llvm.sh`
script. If that bothers you, do not pass `-L`; the archive Clang is the default.

---

## Housekeeping

```bash
docker images --filter=reference='ai-*'      # see accumulated version tags
docker image prune -f                            # untagged layers only
docker rmi ai-ubuntu:26.04-cc2.1.180         # retire an old pinned tag
docker system df                                 # LLVM images are ~4-6 GB each
```

Keep at least the current tag plus one `-prev` per image. Everything else is disposable.

---

## Alternative: self-update mode

If you want `claude update` to work inside the container without an image rebuild, run
with `-u`:

```bash
ai-box -u -- claude
# inside:
claude update      # installs into ~/.local/share/claude, persisted on the host
```

`-u` mounts `~/.local/bin` and `~/.local/share/claude` from the per-image state
directory and clears `DISABLE_AUTOUPDATER`. The native installer's binary then lives in
your state directory and takes precedence on `PATH` over the packaged one.

Tradeoffs, so you can decide deliberately:

- **Loses** the "image tag pins the agent" property. Two containers from the same image
  can now be running different agent versions.
- **Adds** a writable, executable path that persists across sessions - a place where a
  compromised session could leave something behind. It is still inside the state
  directory and still cannot reach the rest of your host, but it is no longer ephemeral.
- **Needs** `downloads.claude.ai` reachable, which matters if you restricted egress.

To go back: stop using `-u`, and delete
`~/.local/share/ai-box/<image>/local-bin` and `…/local-share-claude`.
