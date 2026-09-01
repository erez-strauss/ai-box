# ai-box


Run AI coding agents inside a container that can see **exactly one** project directory on
your host and nothing else. Three images, each with a full C++ and Python build
environment.

**Each image ships the newest compilers it can obtain, not merely the newest its
distribution packages.** On Ubuntu that means GCC 16 rather than the archive default of
15, and Clang from apt.llvm.org rather than the archive's older major. The three images
do not match each other and are not meant to; see decision D3a in
`docs/design-decisions.md`.

| Image | Base | Toolchain | Use it for |
|---|---|---|---|
| `ai-ubuntu:26.04` | Ubuntu 26.04 LTS | GCC 16 as `g++`, GCC 15 alongside, newest Clang obtainable; Python 3.14 | LTS-stable builds, matching a production Ubuntu target |
| `ai-fedora:44` (default) | Fedora 44 | newest GCC and Clang Fedora ships, currently GCC 16.1 and Clang 22; Python 3.14 | C++23/26 feature work, modules, sanitizer-heavy debugging |
| `ai-rocky:10` | Rocky Linux 10 | newest resolvable `gcc-toolset`, put on `PATH` directly so no `scl enable` is needed; Python 3.12 | building against a RHEL/Rocky production target |

`scripts/capabilities.sh` prints what each **built** image actually contains, which is the
authoritative answer since the images differ by design. `scripts/build.sh --toolchain
distro` restricts a build to the distribution's own signed repositories — one fewer
third-party key, an older Clang — and `-g VERSION` pins a specific GCC.

[![CI](https://github.com/erez-strauss/ai-box/actions/workflows/ci.yml/badge.svg)](https://github.com/erez-strauss/ai-box/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Version:** 2.3.10 · **Host assumption:** Ubuntu 24.04 or newer + Docker Engine 28.x,
or Podman 5.x. Fedora and other SELinux hosts are handled; see Podman below.


---

## Why

Claude Code is most useful when it can run commands without asking permission for every
one of them. That is only a reasonable trade if the worst case is bounded. Here the worst
case is "the project directory got mangled", recoverable with `git checkout`, rather than
"something read `~/.ssh` and `~/.aws`".

The container has no host home directory, no SSH keys, no Docker socket, no sudo, no
capabilities, and no way to install anything that outlives the session.

---

## Quick start

### 1. Choose where it lives

The package runs from wherever you extract it: `install.sh` only creates symlinks pointing
back at that directory, so **extract it where you want it to stay**. Moving it later breaks
the symlinks until you re-run `install.sh`.

```bash
mkdir -p ~/src && cd ~/src          # a stable location, not ~/Downloads
tar xzf ~/Downloads/ai-box-v2.3.10.tar.gz
cd ai-box-v2.3.10
scripts/install.sh                  # links ai-box, ai-keys, ai-box-* into ~/.local/bin
```

Each release extracts into its own directory, so several versions can sit side by side and
`install.sh` from whichever one you want active decides which is on `PATH`.

**For several users on one machine**, put the package somewhere readable by all of them and
have each user run `install.sh` for themselves:

```bash
sudo tar xzf ai-box-v2.3.10.tar.gz -C /opt      # /opt/ai-box-v2.3.10, root-owned, world-readable
/opt/ai-box-v2.3.10/scripts/install.sh          # each user, once
```

That gives one copy of the package and per-user state, which is what you want: keys live in
each user's `~/.aikeys` at mode 0700, and container state in each user's
`~/.local/share/ai-box`. **Do not share a key store or a state directory between users** —
they hold credentials and agent sessions.

Images are shared automatically, because the container engine stores them system-wide. One
caveat: an image is built with the UID of whoever built it, so files an agent writes are
owned by that UID. If your users have different UIDs, each should build (or derive) their
own image, or use rootless Podman where the mapping is per user.

### 2. Get the images

```bash
scripts/build.sh --from-registry fedora     # pull a published base: seconds
scripts/build.sh fedora                     # build locally: 10-15 minutes
```

**Start with `--from-registry`.** It pulls the published base image, applies current OS
updates, installs any agents you ask for, and matches your UID. Building locally instead
compiles nothing but does install a full toolchain per image: **roughly 10-15 minutes for
one image and about 35 minutes for all three** (measured: `--agents all all` took 34
minutes on a laptop).

**Build only the image you need.** `all` is rarely what you want on a first run:

| Image | Use it for |
|---|---|
| `fedora` (the default) | newest GCC and Clang; the best choice unless you have a reason |
| `ubuntu` | matching an Ubuntu LTS production target |
| `rocky` | matching a RHEL-family production target |

If the published image is not there — not yet published, registry unreachable, or
`AI_BOX_REGISTRY` pointing elsewhere — the pull fails with an explanation and the local
build command, which needs no registry at all.

### 3. Add a credential and run

```bash
ai-keys init                        # credential store at ~/.aikeys
ai-keys add default                 # paste an API key; input is hidden, no browser needed

cd ~/src/myproject
ai-box -- claude
```

Without a key in the store, `ai-box` falls back to the browser login flow. With one, it
mounts the key read-only and starts straight away; see `docs/credentials.md`.

Useful at any point:

```bash
ai-box --version              # version, where this command lives, which package it uses
ai-box-doctor                 # host setup, image versions, whether an agent has aged
ai-box-capabilities           # what each built image actually contains
```

Inside the container:

```bash
claude --dangerously-skip-permissions
cmake -S . -B "build/$AI_BOX_IMAGE" -G Ninja && cmake --build "build/$AI_BOX_IMAGE" -j$(nproc)
pytest -q
cat /etc/toolchain-versions
```

### From a clone instead

```bash
git clone https://github.com/erez-strauss/ai-box.git
cd ai-box
scripts/install.sh && scripts/build.sh --from-registry fedora
```

---

## How this was built

**ai-box was designed and written with AI coding agents**, largely inside the container it
produces. The collaboration is visible in the repository rather than hidden: `CHANGELOG.md`
records defects candidly, including several introduced by an agent editing code it could
not execute, and `docs/design-decisions.md` records what was considered and rejected.

That history is the reason for the self-checks in `scripts/`. Each exists because something
shipped broken, and most of those failures share one mechanism: an edit that reported
success without changing anything, or a check that passed against the source while the
built image was wrong. A tool for running agents safely ought to be honest about what
working with agents actually costs, so the record is kept rather than tidied.

Reviews by other agents, run from inside a built image, found real defects that source
review had missed. Those findings are in the changelog too.

## What the container can see

This is the whole answer to "how isolated is it?", so it is worth stating exactly.
`$STATE` below is `~/.local/share/ai-box/<image-ref>/`, keyed per image so the Ubuntu
and Fedora boxes never share state.

**Mounted by default, two host directories, both read-write:**

| Host path | In container | Purpose |
|---|---|---|
| your project directory | `/workspace` | The work itself. The only host path holding *your* data, and the only one the agent can damage. |
| `$STATE/claude` | `/home/dev/.claude` | `CLAUDE_CONFIG_DIR`: `.claude.json`, `.credentials.json`, sessions, settings, backups. Persists so you do not re-authenticate every run. Never touches your host `~/.claude`. |

Two, not three: currently the compiler and package caches live inside the project
directory rather than in a third mount of their own. See "Caches" below.

**Mounted only when the situation calls for it:**

| Host path | In container | Mode | When |
|---|---|---|---|
| `~/.aikeys/<profile>.key` | `/run/secrets/ai-key` | read-only | a key profile resolves |
| `~/.aikeys/<profile>.env` | `/run/secrets/ai-key-env` | read-only | that profile has an `.env` |
| `/dev/shm/ai-box.XXXX/key` | `/run/secrets/ai-key` | read-only | `-a pass`; shredded on exit |
| `$STATE/local-bin`, `$STATE/local-share-claude` | `~/.local/{bin,share/claude}` | read-write | `-u` self-update mode only |

**Looks like a mount but is not a host directory:**

- `/tmp` is a 4 GB **tmpfs**: RAM, never touches your disk, gone when the container exits.
  It is mounted `exec` so compiled test binaries can run, and `nosuid,nodev`.
- `/opt/venv` is a directory **inside the image**. Anything you `pip install` there lives
  and dies with the container.
- `~/.cache` inside the container is a **symlink into `/workspace`**, not a directory of
  its own. It resolves to a path in the project you mounted.
- `/opt/toolchains` is a **named volume** (`ai-toolchains`), auto-mounted only if you
  created it. The engine owns it; it is not a path in your home directory.
- `-a envfile` is not a mount at all: the values are copied into the environment, which is
  why it is the weakest option. They are visible in `docker inspect`.

**Deliberately not mounted:** `$HOME`, `~/.ssh`, `~/.gitconfig`, `~/.aws`,
`/var/run/docker.sock`, and any directory containing many projects. `ai-box` refuses
the tree paths (`$HOME`, `/`, `/home`, `/root`, `/etc`, `/usr`, `/var`, `/opt`, `/boot`,
`/proc`, `/sys`, `/dev`, `/srv`, `/mnt`, `/media`) *and* the credential-bearing ones
(`~/.aikeys`, its own state directory, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`,
`~/.docker`, `~/.config`, `~/.local`) as the project argument. A directory this README
calls unreachable is not mountable by hand either.

So the practical blast radius is **your project directory plus ai-box's own state**.
Credentials are read-only single files, not directories. Verify it rather than taking it
on trust:

```bash
scripts/verify-isolation.sh ubuntu
```

That check reads the argv `ai-box -n` prints and asserts against it, so it cannot pass
while the wrapper regresses. It once built its own copy of the flags, and would
have reported PASS on a wrapper with no `--cap-drop=ALL` at all.

---

## Every file in the package

One entry per file, grouped by directory. This table is authoritative and is checked
by `scripts/check-file-inventory.sh` on every push, so a file added without a line here
fails CI rather than quietly becoming undocumented.

Everything ships in the release tarball except the last group, which is repository
infrastructure that only means anything on GitHub.

<!-- BEGIN FILE INVENTORY -->

**Package root: what this is, and the rules it is held to**

| Path | What it is, and why it exists |
|---|---|
| `README.md` | This file. Quick start, the mount inventory, and this table. |
| `AGENTS.md` | The working agreement for changing this package: hard rules, style, definition of done, and the split between what a session inside the box can finish and what needs a host. Applies to every agent and to humans. |
| `CLAUDE.md` | A pointer to `AGENTS.md`, plus the Anthropic-specific notes. It exists because Claude Code reads this exact filename. |
| `CHANGELOG.md` | Every release, with the reasoning. `VERSION`, the heading here, and the release tag must agree; CI enforces it. |
| `CONTRIBUTING.md` | How to propose a change, the checks to run first, and the three mistakes this codebase has already made. |
| `SECURITY.md` | What the sandbox claims, what it explicitly does not claim, and how to report a weakness privately. |
| `LICENSE` | MIT. |
| `VERSION` | Single source of truth for the version number. Never hardcode it elsewhere. |
| `.dockerignore` | Keeps the build context small. The context is the package root, so without this every doc and script would be shipped to the daemon on each build. |
| `.gitignore` | Build leftovers, release archives, and credential-shaped filenames as a backstop. A key that reaches a commit has left the machine; this reduces the odds. |
| `.hadolint.yaml` | Dockerfile lint configuration. Every ignored rule carries its justification, on the same principle as a `# shellcheck disable=` comment. |

**`docker-ubuntu/`, `docker-fedora/`: one image each, distro-specific logic only**

| Path | What it is, and why it exists |
|---|---|
| `docker-ubuntu/Dockerfile.ai-ubuntu` | Ubuntu 26.04 LTS: GCC 15 and 16 and Clang 21 from the Ubuntu archive, the `/opt/venv` Python environment, Claude Code from the signed apt repository with a fatal GPG fingerprint check, and an unprivileged user whose UID matches yours. |
| `docker-fedora/Dockerfile.ai-fedora44` | The same contract on Fedora 44, with whatever compilers Fedora ships. Behaviourally equivalent to the Ubuntu image by hard rule 10: same entrypoint, same user, same paths, same environment variable names. |
| `docker-rocky/Dockerfile.ai-rocky10` | The same contract on Rocky Linux 10, for building against a RHEL-family production target. Differs in one substantive way: RHEL pins a conservative system GCC and ships newer compilers as Software Collections, so this image probes for the newest `gcc-toolset`/`llvm-toolset` available and puts it directly on `PATH` rather than requiring `scl enable`. |
| `docker-derive/Dockerfile.derive` | Adds agents, package updates and a matching UID to a **published** base image, without rebuilding it. Deliberately not a full image definition: no entrypoint, no user creation, no cache layout, all inherited from the base. Used by `build.sh --from-registry`. |

**`shared/`: COPYed into every image, plus configuration templates**

| Path | What it is, and why it exists |
|---|---|
| `shared/entrypoint.sh` | The common container entrypoint. Reads the mounted credential, exports the variable its `kind:` calls for, marks `/workspace` a safe git directory, and prints the first-run banner. Distro-agnostic on purpose. |
| `shared/keyfile-lib.sh` | The one key-file parser, sourced by `lib-common.sh` on the host and COPYed into every image. Three copies of this logic once disagreed about a `kind:` line with no space and about a secret containing `=`; both showed up only as an unexplained HTTP 401. Hard rule 13 says there may only ever be one. |
| `shared/install-agents.sh` | Installs the opt-in third-party agents (`codex`, `gemini`, `grok`). One file for all three images, because each vendor distributes differently and that variation should live in one place. Documents why the vendors' `curl \| bash` installers are not used. |
| `shared/install-langs.sh` | Installs the opt-in language toolchains (`rust`, `go`, `java`, `node`, `ruby`, `lua`). One table of per-distribution package names, because that is the part that differs and drifts. Documents why rustup is not run during a build. |
| `shared/toolchain-report.sh` | Runs at build time and writes `/etc/toolchain-versions`, so `docker run --rm IMG cat /etc/toolchain-versions` answers "which compilers?" without starting a shell. |
| `shared/settings.example.json` | Claude Code settings for inside the container. Auto-updates are off because the agent is pinned by the image tag. |
| `shared/anthropic.env.example` | Template for the legacy `-a envfile` credential mode. Deliberately not installed by `install.sh`: a placeholder that looks like a secret on disk caused more confusion than it saved. |
| `shared/tinyproxy.conf.example` | Egress allowlist for the optional proxy sidecar, if you want to restrict where the container can send data. |
| `shared/compose.yaml` | A `docker compose` alternative to the wrapper. It does not resolve key profiles, stage a `pass` secret, apply the mount guard, or clean up afterwards, so prefer `ai-box`. |

**`scripts/`: host side. Every script sources `lib-common.sh`.**

| Path | What it is, and why it exists |
|---|---|
| `scripts/ai-box` | The wrapper you actually run. Resolves the credential, applies the mount guard, and builds the `docker run` or `podman run` command with `--cap-drop=ALL`, `no-new-privileges`, a non-root `--user`, and exactly one project directory. `-n` prints that argv instead of running it. |
| `scripts/ai-keys` | The credential store manager for `~/.aikeys`: add, list, link, check, test. Reads keys from a terminal with echo off, prints fingerprints rather than secrets. |
| `scripts/lib-common.sh` | Shared definitions: image references, state paths, the container engine selection, SELinux mount options, logging. Sourced, never executed, so it carries no execute bit. |
| `scripts/build.sh` | Builds one image or all of them. Owns the OS-update policy, the toolchain and Python build arguments, and the version tagging. |
| `scripts/check-updates.sh` | Read-only comparison of the Claude Code installed in each image against what its signed channel currently offers. |
| `scripts/upgrade.sh` | Rebuilds with a newer or pinned agent, keeping a `-prev` tag so a rollback is one `docker tag` away. |
| `scripts/verify-isolation.sh` | Proves the sandbox holds. Asserts against the argv `ai-box -n` prints rather than rebuilding the flags itself, checks that every bind source is the project or the state directory, probes the running container for capabilities and writability, and confirms `-N none` really blocks name resolution. |
| `scripts/smoke-test.sh` | Proves the image works: the agent runs, every compiler compiles and runs C++23, the `/opt/venv` tools resolve and the venv is writable without root, and the `examples/` reflection programs build on any compiler that has reflection. |
| `scripts/doctor.sh` | Diagnoses the host side before you blame the container: engine reachable, which images exist, key file modes, which profile this directory resolves to, credential-looking files inside a project, config validity. `--fix` repairs the mechanical problems only. |
| `scripts/check-file-inventory.sh` | Compares this table against the files actually present, so the inventory cannot rot. |
| `scripts/check-doc-links.sh` | Every `docs/…` path mentioned anywhere in the package must exist. The inventory check catches a file with no row; this catches the opposite, a reference to a document that is not there. Run by `pack.sh`. |
| `scripts/ci-local.sh` | Runs locally exactly what CI runs, from one definition: the workflow calls this script rather than repeating the commands. `--with-images` adds the slow half. Warns if run as root, because CI runs unprivileged and root hides failures. |
| `scripts/check-image-parity.sh` | Asserts every Dockerfile still implements the shared contract: the markers each image must define, and any `${VAR}` used but never declared. Hard rule 10 was prose until this existed, and prose does not fail a build. |
| `scripts/install.sh` | Symlinks the entry points into `~/.local/bin` and creates the host directories with the right modes. |
| `scripts/pack.sh` | Builds `ai-box-v<VERSION>.tar.gz` from an explicit allowlist of members, refuses to overwrite a released archive, and verifies the finished archive has exactly one top-level entry. |
| `scripts/stamp-version.sh` | Rewrites every `ai-box-v<version>` in the documentation to match `VERSION`, plus the header lines. A line marked `stamp:keep` is left alone, and the changelog is never touched. Keeps the version in the documentation equal to `VERSION`, and `--check` fails when it drifts. `pack.sh` runs the check, so a stale stamp cannot ship. Deliberately narrow: it rewrites four anchored patterns and leaves historical prose like "currently the caches live in the workspace" alone. |
| `scripts/capabilities.sh` | Installed as `ai-box-capabilities`. Reads `/etc/toolchain-versions` out of each built image and prints one table. The images deliberately carry different toolchain versions, so what each one has is a real question; this answers it from what shipped rather than from the Dockerfiles. `--markdown` for pasting here. |
| `tests/run.sh` | Runs every test file. Plain bash, no framework, so it runs from an extracted tarball. |
| `tests/_harness.sh` | Assertions. Each runs in a subshell, because the functions under test call `die()`. |
| `tests/keyfile-lib.test.sh` | The key parser, including both historical bugs as named cases. |
| `tests/lib-common.test.sh` | Hostname derivation, image refs, state fallback, profile precedence, the credential guard, JSON validation. |
| `tests/mount-guard.test.sh` | The mount guard, exercised through `ai-box -n` rather than by re-implementing its logic. Every case comes from a review that found the guard was an exact match, so `/etc` was refused while `/etc/ssh`, `/var/log` and `/root/.ssh` were not. |

**`docs/`: operator documentation, versioned filenames**

| Path | What it is, and why it exists |
|---|---|
| `docs/operating-guide.md` | Full operating guide: threat model, credentials, network, storage, troubleshooting. |
| `docs/credentials.md` | Credentials without a browser, per-project keys, CI usage. |
| `docs/upgrading.md` | Keeping the agents and the images current, with rollback. |
| `docs/design-decisions.md` | Why the design is what it is, and what is still open. |
| `docs/ai-box-project-roadmap.md` | Proposed next steps, a strategic comparison with similar projects, candidate tooling, and the MCP question. Proposals, not a plan of record; settled decisions live in `docs/design-decisions.md`. |
| `docs/ide-clion.md` | Editing, building and debugging inside these images from CLion. Covers the Docker toolchain setup per image, the Container Settings a debugger needs, and the cache trap that comes from CLion mounting the project somewhere other than `/workspace`. |
| `docs/project-template.md` | A `CLAUDE.md` to copy into a project opened in the box. Covers the four things agents reliably try and cannot do here: `sudo`, installing system packages, `pip install` into the system Python, and building in the source tree. |

**`.github/`: repository infrastructure. Not shipped in the release tarball.**

| Path | What it is, and why it exists |
|---|---|
| `.github/workflows/ci.yml` | Lint, package invariants, and a matrix image build that runs the isolation and smoke checks. Also runs weekly, which is the run that catches distro package renames before a user does. |
| `.github/workflows/release.yml` | Fires on a `v*` tag. Refuses to publish unless the tag, `VERSION` and the changelog heading agree, then attaches the tarball and `SHA256SUMS`. |
| `.github/workflows/publish-images.yml` | Publishes the three base images to GHCR on a tag, **without optional agents**: a public image carrying four vendors' CLIs is a redistribution question, and users add theirs locally with `build.sh --from-registry --agents`. Verifies isolation and smoke before pushing. |
| `.github/dependabot.yml` | GitHub Actions updates only. There is no lockfile here to update; distro packages are pinned by the base image tag. |
| `.github/pull_request_template.md` | Asks what the change does to the boundary, and lists the checks that must have been run. |
| `.github/ISSUE_TEMPLATE/bug_report.yml` | Asks for the version, image, runtime and `doctor.sh` output, and warns against pasting a credential. |
| `.github/ISSUE_TEMPLATE/feature_request.yml` | Asks whether the proposal changes what the container can reach, before anything else. |
| `.github/ISSUE_TEMPLATE/config.yml` | Routes suspected sandbox weaknesses to a private advisory, and Claude Code bugs upstream. |

<!-- END FILE INVENTORY -->

## Commands

| Command | Does |
|---|---|
| `ai-box` | interactive shell in the **default image (Fedora)**, `$PWD` at `/workspace` |
| `ai-box -i ubuntu` / `-i rocky` | pick another image for one run |
| `ai-box -i fedora -- claude` | Fedora image, straight into the agent |
| `ai-box -k work -- claude` | use the `work` key profile from `~/.aikeys` |
| `ai-box -a login -- claude` | ignore the key store, do the browser OAuth flow |
| `ai-box -a pass -- claude` | API key read from `pass`, mounted as a file, never in env |
| `ai-keys add \| list \| link \| check \| test` | manage credentials without a browser |
| `ai-box -d` | add `SYS_PTRACE` + unconfined seccomp for gdb/valgrind |
| `ai-box -u` | persist `~/.local/{bin,share/claude}` so `claude update` survives |
| `ai-box -N none` | no network at all (build/inspect only) |
| `ai-box -n` | print the exact run argv and exit, without running it |
| `scripts/check-updates.sh` | is there a newer Claude Code? |
| `scripts/build.sh --no-updates -t 26.04.1` | reproducible build: no package upgrades, pinned base tag |
| `scripts/build.sh --python-tools "…"` | change the Python tools baked into `/opt/venv` |
| `scripts/upgrade.sh [-c X.Y.Z]` | rebuild images with the newer/pinned agent + OS updates |
| `scripts/verify-isolation.sh ubuntu` | prove the sandbox holds |
| `scripts/smoke-test.sh ubuntu` | prove the agent, every compiler and the venv work |
| `scripts/doctor.sh [--fix]` | diagnose host-side setup: keys, modes, config validity, images |
| `scripts/pack.sh [--stage]` | produce `ai-box-v<VERSION>.tar.gz` |

---

## Credentials

Full treatment in **`docs/credentials.md`**. The short version:

- **`~/.aikeys`** (default): one file per profile, mode 0600, mounted read-only into
  the container. Works with a Console API key with no browser at any point, or with a
  long-lived OAuth token from `claude setup-token`. Per-project keys via `ai-keys link`
  or a `.ai-profile` file naming the profile.
- **`login`**: the browser OAuth flow; the token persists in the per-image state directory
  and never touches your host `~/.claude`.
- **`pass`**: GPG-backed; staged on `/dev/shm`, bind-mounted, shredded when the container
  exits. Set `AI_BOX_PASS_KIND` if the entry is not an API key.
- **`apiKeyHelper`**: for vault-issued rotating credentials.

No credential is ever baked into an image layer or a build arg, and `ai-box` refuses a
key file stored inside the mounted project directory: that directory is writable by the
agent and one `git add .` from a public repo. It also refuses a `.ai-profile` that
holds a key rather than a profile name, and says to revoke it, because that file is meant
to be committed.

One parser, `shared/keyfile-lib.sh`, reads a key profile for both the host scripts and the
container entrypoint, so the two ends cannot disagree about what a profile means.

---

## Caches

Every cache belongs to the project being worked on, so it lives in the project
directory and is deleted with it:

| Path in your project | Holds |
|---|---|
| `.ccache-ubuntu/`, `.ccache-fedora/` | `CCACHE_DIR`, the compiler cache |
| `.cache-ubuntu/`, `.cache-fedora/` | `XDG_CACHE_HOME` and the target of `~/.cache`: pip, uv, and anything else that follows the convention |

Each is created on first use with a `.gitignore` containing `*`, so the tree ignores
itself and no project has to remember an entry.

They are per image because the three images differ in compiler, libc and Python minor
version. ccache would in fact be safe to share, since it keys on a hash of the compiler
binary, but pip is not: a wheel built from an sdist carries the tag `linux_x86_64` under
both distros, so one compiled with Fedora's toolchain could be reused under Ubuntu's.

The trade this makes, stated so it is not rediscovered as a bug: a cache per project does
not share compilations between projects the way one cache per image did, and it uses more
disk in aggregate. `CCACHE_MAXSIZE` is 2G rather than the 10G that suited a single shared
cache. If you would rather have the old behaviour, point `CCACHE_DIR` back out of the
project:

```bash
ai-box -- bash -lc 'CCACHE_DIR=$HOME/.claude/ccache cmake --build build/gcc'
```

If the workspace is read-only, or the image is run with nothing mounted at all, the
caches fall back to `/tmp`, which is a tmpfs, and the session still works.

## Python

All three images ship a ready virtualenv at `/opt/venv`, first on `PATH` and owned by the
unprivileged user, so `python`, `pip`, `ruff`, `mypy`, `pytest` and `uv` work immediately
and `pip install` inside a session succeeds without root. Both distros enforce PEP 668,
which refuses `pip install` into the system interpreter; the venv sidesteps that without
resorting to `--break-system-packages`.

Anything you `pip install` at run time is ephemeral, which is the point: the image stays
reproducible. To make an addition permanent, put it in the build:

```bash
scripts/build.sh --python-tools "uv ruff mypy pytest pandas numpy" ubuntu
```

`uv` is included because it is the quickest route to an interpreter other than the
distro's: `uv venv --python 3.13` inside a session, or bake one into the image with
`--uv-python 3.13`.

---

## Running with Podman

Everything works under Podman. Set the engine once and every script follows:

```bash
export AI_BOX_ENGINE=podman

scripts/build.sh all
scripts/verify-isolation.sh ubuntu
ai-box -- claude
```

Podman is worth considering rather than merely tolerating. Rootless Podman has no daemon
running as root and no `docker` group, and membership in that group on a rootful Docker
daemon is equivalent to host root. Removing it removes a whole class of escalation that
this project otherwise has to document rather than prevent.

Three differences the scripts handle for you, listed because they are the ones that bite
anyone who tries the naive `alias docker=podman`:

**User namespaces.** Rootless Podman maps you to container UID 0 and every other UID to a
subordinate one. Without `--userns=keep-id`, the container's `dev` user (whose UID equals
yours by build argument) lands on a subuid, and every file the agent writes into `/workspace`
comes out owned by a number that is nobody on your host. `ai-box` adds `keep-id`, and
`verify-isolation.sh` asserts it is there, because every hardening flag can be correct
while file ownership is still wrong.

**SELinux.** On a Fedora or RHEL host, a bind mount with no label option is unreadable
inside the container and the error is a bare "permission denied". The scripts append `,z`
(the shared label, not the private `Z`, since your editor and build server also use that
directory) to the bind mounts, and `relabel=shared` to the credential mount, but only when
`selinuxenabled` reports the host is actually enforcing. On a Debian or Ubuntu host
nothing is added.

**Subordinate ID ranges.** Rootless Podman needs an entry for you in `/etc/subuid` and
`/etc/subgid`. Most distributions create one at user-creation time; if yours did not,
`sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER` followed by
`podman system migrate` fixes it. `scripts/doctor.sh` checks for this and says so.

If you would rather not set the variable, `podman-docker` (or a `docker` symlink pointing
at `podman` on your `PATH`) also works, but then `keep-id` is not added for you. Put
`userns = "keep-id"` in the `[containers]` section of `~/.config/containers/containers.conf`
if you go that route. Setting `AI_BOX_ENGINE` is the supported path.

Resource limits (`--memory`, `--cpus`, `--pids-limit`) need cgroups v2 with delegation,
which is the default on any current distribution. If Podman warns that it is ignoring
them, `AI_BOX_MEMORY` and `AI_BOX_CPUS` are advisory on that host and the
isolation is unaffected.

---

## Two ways to get the images

```bash
scripts/build.sh all                                  # build locally, ~40 min
scripts/build.sh --from-registry all                  # pull the published base, seconds
scripts/build.sh --from-registry --agents codex all   # ...and add an agent locally
```

Both produce the same tags, so everything else is identical. Building locally keeps the
whole supply chain inspectable; `--from-registry` trades that for minutes. Refresh either
with `scripts/upgrade.sh` or `scripts/upgrade.sh --from-registry`.

## Published images

Building from source takes tens of minutes, mostly compilers. The three base images are
published so you do not have to:

```bash
scripts/build.sh --from-registry all                 # pull and derive, seconds
scripts/build.sh --from-registry --agents codex all  # with an agent added locally
scripts/upgrade.sh --from-registry all               # refresh later
```

**Published images carry no optional agents.** That is deliberate on two grounds: a public
image containing four vendors' CLIs is a redistribution question that each vendor's terms
answer differently, and most people want one agent rather than all of them. So the
published artifact is the expensive part — compilers, Python, analysis tooling — and
`--from-registry` adds the cheap part locally: package updates, the agents you asked for,
and a UID matching yours.

That last point matters. A published image is built with a fixed UID; if yours differs,
every file the agent writes would be owned by someone else on your host. The derive step
remaps it, and is a no-op when they already match.

`docker-derive/Dockerfile.derive` does this, and it deliberately defines no entrypoint,
user or cache layout: it inherits all of that from the base, which is why
`check-image-parity.sh` skips it. Agents are installed by the same
`shared/install-agents.sh` a from-source build uses, Node included, so both paths behave
identically.

Building from source remains the default and stays fully supported; nothing about the
supply chain becomes unavailable by publishing.

## Other AI agents

Claude Code is always installed, from Anthropic's signed apt/dnf repository with a GPG
fingerprint check.

**Every other agent is off by default.** A plain `scripts/build.sh all` gives you images
with Claude Code and nothing else -- no `codex`, no `gemini`, no `grok`, and no Node
runtime. That default holds at three independent points, so a build cannot pick one up by
accident:

| Layer | Default | Effect |
|---|---|---|
| `scripts/build.sh` | `AI_AGENTS=""` | the `--build-arg` is not passed at all |
| Dockerfile | `ARG AI_AGENTS=""` | the image's own default applies |
| `shared/install-agents.sh` | empty exits 0 | prints "no optional agents requested" |

Opt in per build:

```bash
scripts/build.sh fedora                        # Claude Code only (the default)
scripts/build.sh fedora --agents codex         # + one static binary, no runtime added
scripts/build.sh fedora --agents codex,gemini  # + Node and npm pulled into the image
scripts/build.sh fedora --agents all           # every agent this package supports
scripts/build.sh fedora --agents none          # explicit form of the default
```

`all` expands from the list in `shared/install-agents.sh`, so it follows that file as
agents are added rather than needing to be kept in step by hand. An unrecognised name is
rejected before the build starts, not twenty minutes in.

The default is deliberate rather than an oversight, and worth overruling if it does not
match how you work: every extra agent is another binary with network access, its own
credential, and its own update cadence, inside a container whose entire purpose is a
small blast radius. `codex` is the cheap one. `gemini` and `grok` drag a Node runtime
into an image that otherwise has none.

| Agent | Vendor | How it installs | Native Linux binary? |
|---|---|---|---|
| `claude` | Anthropic | signed apt/dnf repo, fingerprint-checked | yes, always present |
| `codex` | OpenAI | static Rust binary (musl) from GitHub Releases | **yes** |
| `gemini` | Google | npm `@google/gemini-cli` | no, Node only |
| `grok` | xAI | npm `@xai-official/grok` | no, Node only |

Only OpenAI ships a genuinely native Linux executable; it needs no runtime at all.
Requesting `gemini` or `grok` pulls Node and npm into the image, which is why they are
not on by default. The vendors' `curl … | bash` installers are deliberately **not** used:
piping an unpinned remote script into a shell during an image build is exactly what this
project exists to avoid, and npm at least pins a version and records an integrity hash.

Each agent reads its own credential variable, so a key profile must declare which vendor
it belongs to:

```bash
ai-keys add openai-work     # kind: openai -> OPENAI_API_KEY
ai-keys add gemini-work     # kind: gemini -> GEMINI_API_KEY
ai-keys add grok-work       # kind: grok   -> GROK_CODE_XAI_API_KEY
```

`ai-keys` infers the kind from the key prefix where the vendor uses a distinctive
one, and the `kind:` line in the profile always wins. Access tiers differ and change:
Gemini CLI dropped free-account access in June 2026, and Grok Build is subscription-gated.
Check the vendor's current terms rather than this table.

## Static linking

Every image can link fully static C++ executables, and both the build and the smoke test
assert it rather than assuming:

```bash
g++ -std=c++23 -static main.cpp -o app
g++ -static-libstdc++ -static-libgcc main.cpp -o app   # usually the better choice
```

`libc.a`, `libm.a`, `libstdc++.a` and `libgcc.a` are present in all three images, with
`zlib` and `openssl` static archives as optional extras and `musl-gcc` where the
distribution packages it.

One caveat worth knowing before shipping a static binary: glibc resolves hostnames and
users through NSS modules loaded at run time, so a fully static glibc binary still needs
matching glibc shared objects if it calls `getaddrinfo` or `getpwnam`, and the linker warns
about exactly that. `docs/operating-guide.md` §7a explains the three ways round it.

## Other languages

C++ and Python are the base image and are always present. Other toolchains are opt-in, at
build time, from the distribution's own repositories:

```bash
scripts/build.sh --lang rust fedora                 # from source
scripts/build.sh --from-registry --lang rust,go all # onto a published base, seconds
```

Known names: `rust`, `go`, `java`, `node`, `ruby`, `lua`, or `all`. The per-distribution
package names live in one place, `shared/install-langs.sh`, because the difficulty of this
feature is that the names differ between distributions and move between releases. They are
installed as optional leaves, so a name that has moved logs a note instead of breaking the
build, and the installer prints what actually landed.

**What this is not.** It is a supported seam instead of a fork, not a promise of
first-class support per language. This project's identity is C++ and Python done properly;
breadth is [claudebox](https://github.com/RchGrav/claudebox)'s job, and doing it badly
would be worse than not doing it. If a language needs more than its distro packages, add
it to the Dockerfile and rebuild, which is the mechanism `--lang` is a shortcut for.

**Distro toolchains lag upstream, and for Rust the gap can be large.** The upstream
installer is `curl https://sh.rustup.rs | sh`, which this project will not run during an
image build for the same reason it refuses the agent vendors' installers: an unpinned
remote script executed at build time is exactly what the package exists to avoid. If you
need a specific Rust, install rustup into your *project* at run time, where it is your
decision rather than a property of the image:

```bash
ai-box -- bash -lc 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- --no-modify-path -y'
```

Keep it under `/workspace` so it persists with the project and not with the image.

## OS freshness vs. reproducibility

Builds apply **every pending distro update by default** and pull a fresh base image, so an
image never quietly rots. The build stamps the date into a layer so the engine cannot reuse
a stale upgrade layer.

```bash
scripts/build.sh all                            # current everything (default)
scripts/build.sh --no-updates all               # packages exactly as the base tag shipped
scripts/build.sh --no-updates -t 26.04.1 all    # reproducible rebuild of a known image
scripts/build.sh -t 26.04@sha256:… ubuntu       # digest-pinned base
```

`docker inspect` reports which mode built an image, via `com.ai-box.os-updates` and
`com.ai-box.update-stamp`.

## Upgrading

The agent version is pinned by the image tag, so upgrading means rebuilding:

```bash
scripts/check-updates.sh
scripts/upgrade.sh              # keeps a :…-prev tag for one-command rollback
```

Full detail, including channels, pinning, automation, and the self-update alternative:
`docs/upgrading.md`.

---

## Versioning and packaging

`VERSION` is authoritative. Every release ships as `ai-box-v<VERSION>.tar.gz` whose
single top-level directory is `ai-box-v<VERSION>/`. Extracting several releases
into the same parent directory therefore never overwrites anything:

```bash
tar xzf ai-box-vOLD.tar.gz
tar xzf ai-box-vNEW.tar.gz
ls -d ai-box-v*/     # both directories, side by side, nothing overwritten
```

`scripts/pack.sh` enforces this: it refuses to run if the directory name and `VERSION`
disagree, refuses to overwrite an archive that already exists, ships an explicit allowlist
of package members rather than "everything except", and verifies the finished archive
really does have exactly one top-level entry. From a git checkout, where the directory is
named after the repository, pass `--stage`.

Releases are cut by tagging: `git tag v2.3.10 && git push origin v2.3.10`. The release
workflow refuses to publish if the tag, `VERSION` and `CHANGELOG.md` disagree, then
attaches the tarball and `SHA256SUMS` with that version's changelog section as the notes.

---

## How this compares to other projects

Running a coding agent in a container is a well-populated space and this is not the
only reasonable answer. The comparison below is drawn from each project's own
documentation, checked August 2026. Projects move; verify before you rely on a cell.

| | host paths mounted | capabilities | credential | network policy | toolchain |
|---|---|---|---|---|---|
| **ai-box** (this) | project dir + own per-image state, nothing else | **`--cap-drop=ALL`**, `no-new-privileges`, non-root, no sudo | read-only file mount, never `--env`; refuses a key inside the project dir | unrestricted by default; `-N none`, or an opt-in proxy sidecar | **deep**: GCC 15/16, Clang 21/22, Python venv, pinned by image tag |
| [Anthropic dev container](https://github.com/anthropics/claude-code/tree/main/.devcontainer) | workspace bind, plus named volumes for config and shell history | **adds `NET_ADMIN` + `NET_RAW`**, runs as `node`, sudo for the firewall script | devcontainer default | **default-deny egress** via iptables/ipset allowlist | Node-based devcontainer |
| [FoamoftheSea/claude-code-sandbox](https://github.com/FoamoftheSea/claude-code-sandbox) | source dir only | non-root `devuser`, sudo narrowed to one script | subscription auth in a Docker volume; explicitly says not to set `ANTHROPIC_API_KEY` | **Squid egress proxy**, SNI allowlist, peek-and-splice (no MITM) | general purpose |
| [RchGrav/claudebox](https://github.com/RchGrav/claudebox) | cwd, **plus host `~/.claude` read-only**, per-project data dirs, tmux sockets | non-root matching UID/GID; `--enable-sudo` opt-in | `ANTHROPIC_API_KEY` environment variable | per-project firewall allowlists | **broad**: 15+ profiles (C/C++, Python, Rust, Go, Java, ML, …) |
| [dagger/container-use](https://github.com/dagger/container-use) | a git branch and container per agent | Dagger-managed | agent's own | Dagger-managed | any, chosen per environment |
| [Claude Code's built-in sandbox](https://code.claude.com/docs/en/sandboxing) | no container: writes confined to the working directory | Seatbelt (macOS) or bubblewrap (Linux/WSL2) | your normal login | proxy allowlist | **none**: your host's toolchain |

### The trade this project makes, stated plainly

**You can have `--cap-drop=ALL` or in-container egress filtering, not both.** Filtering
outbound traffic from inside the container means running iptables inside the container,
which needs `NET_ADMIN`. Anthropic's dev container adds `NET_ADMIN` and `NET_RAW` and
gets a default-deny allowlist; this project drops every capability and gets no egress
filtering by default. Neither is wrong. They optimise for different fears:

- If your worry is **what the agent can read** (your SSH keys, your other repos, your
  cloud credentials), the capability-dropping, one-directory approach here is the tighter
  answer, and `scripts/verify-isolation.sh` will prove it on your machine.
- If your worry is **where the agent can send data**, an egress allowlist is what you
  actually need, and the Anthropic dev container or the Squid-proxy approach in
  FoamoftheSea/claude-code-sandbox is a better starting point than this. The proxy
  sidecar in `docs/operating-guide.md` section 8 gets you there without giving the
  agent's own container `NET_ADMIN`, but it is opt-in and it is more setup.

### Where the others are better

- **Breadth of languages.** RchGrav/claudebox ships 15+ profiles. This package does two
  languages, C++ and Python, properly: three compilers, a matched Python environment, and
  a smoke test that compiles and runs with each of them. If you work in Go or Rust, take
  claudebox.
- **Network defaults.** Both the Anthropic dev container and FoamoftheSea's sandbox
  restrict egress out of the box. Here it is unrestricted unless you configure it.
- **Parallel agents.** dagger/container-use gives each agent its own container *and* its
  own git branch, and records every command into an inspectable remote. If your problem
  is several agents at once rather than one agent's blast radius, that is the right tool.
- **Zero setup.** Claude Code's built-in `/sandbox` needs no image at all. If you want
  most Bash commands to stop prompting and you do not need a reproducible toolchain, it
  is a smaller commitment than anything on this page.

### Where this one is different

- **The credential never enters the environment.** It arrives as a read-only file mount,
  so it does not appear in `docker inspect`, and one parser (`shared/keyfile-lib.sh`)
  reads it on both the host and the container so the two ends cannot disagree. Most
  alternatives pass `ANTHROPIC_API_KEY` as an environment variable.
- **The isolation claim is executable, and it checks the real command.**
  `verify-isolation.sh` reads the argv `ai-box -n` prints rather than rebuilding the
  flags itself, so it fails when the wrapper regresses instead of passing anyway.
  FoamoftheSea's `test-sandbox.sh` is the other project here that tests its own controls;
  it is good company to be in and the approach deserves to be more common.
- **The host home directory is never mounted, not even read-only.** Several wrappers bind
  host `~/.claude` in to reuse your login. This keeps a separate per-image state
  directory instead, so a container cannot read or corrupt your host Claude Code state.
- **Reproducibility is a first-class option.** `--no-updates` with a pinned base tag and a
  pinned agent version rebuilds a specific historical image; the default does the
  opposite and applies every pending distro update so an image cannot quietly rot.

### Further reading

Two curated lists cover far more ground than the table above:
[webcoyote/awesome-AI-sandbox](https://github.com/webcoyote/awesome-AI-sandbox), which
groups by mechanism (host-level, microVM, container, policy layer, low-level primitives),
and [Docker's write-up](https://www.docker.com/blog/run-claude-code-with-docker/) on
running Claude Code with Docker sandboxes. Also worth knowing about:
[rvaidya/claude-code-sandbox](https://github.com/rvaidya/claude-code-sandbox),
[nkrefman/claude-sandbox](https://github.com/nkrefman/claude-sandbox),
[todd-working/claude-code-container](https://github.com/todd-working/claude-code-container),
[boxlite-ai/claudebox](https://github.com/boxlite-ai/claudebox) (microVMs rather than
containers), and
[jlasserre/claude-code-docker-sandbox](https://github.com/jlasserre/claude-code-docker-sandbox),
which forwards your GitHub credentials into the container so `gh` works inside. That last
one is the exact opposite of the choice made here, and deliberately so on both sides: a
credential the agent can reach is a credential the agent can misuse, so `ai-box` keeps
`~/.ssh` and `~/.gitconfig` out and expects you to push from the host.

**If the kernel is in your threat model**, nothing on this page survives a kernel escape.
gVisor (`--runtime=runsc`), Kata Containers, a microVM runner, rootless Podman, or a plain
VM all raise that floor; see `docs/operating-guide.md` section 10.

---

## What this does not protect against

Container escape via a kernel bug; exfiltration over the network (unless you add the egress
allowlist in `docs/operating-guide.md` section 8); and damage to the project directory you
deliberately mounted. `scripts/verify-isolation.sh` asserts the rest, against the argv
`ai-box -n` prints rather than against a copy of it. Keep the project in git and push
often. For a stronger boundary, use rootless Podman, rootless Docker, or a VM-backed
runtime; section 10 of the same document.
