# Running Claude Code in an isolated container

**Package:** ai-box v2.3.8

**Host assumption:** Ubuntu 24.04 LTS or newer ("ubuntu 2.8" read as 24.04) with Docker
Engine 28.x, or Podman 5.x on any host including Fedora and RHEL. The host release does
not have to match the image release. Everything below says "docker" for brevity; set
`AI_BOX_ENGINE=podman` and the same commands run under Podman, with the three
differences described in §0a.
**Companions:** `README.md` (quick start), `docs/upgrading.md` (keeping the
agent current), `CLAUDE.md` (rules for editing this package).

All paths below are relative to the package root, i.e. the directory this archive
extracted into (`ai-box-v2.3.8/`).

The goal: Claude Code can read and write exactly one project directory and nothing
else on your machine. No `~/.ssh`, no `~/.aws`, no browser profiles, no other repos,
no Docker socket. Because the blast radius is bounded, you can run the agent with
permission prompts disabled and let it work.

---

## 0. Prerequisites

```bash
# Docker Engine 28.x from Docker's own repo (Ubuntu's docker.io package lags).
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"   # log out / back in, or: newgrp docker
docker version                     # expect Client & Server 28.x
```

Two notes before you go further:

- Membership in the `docker` group is equivalent to root on the host. If that
  bothers you - and for this use case it reasonably might - use **rootless Docker**
  instead. See §10.
- You need a Claude Pro, Max, Team, Enterprise, or Console (API) account. The free
  claude.ai plan does not include Claude Code.

---

## 0a. Podman instead of Docker

Podman is fully supported and, rootless, is the stronger default: no daemon running as
root, and no `docker` group, which on a rootful daemon is equivalent to host root. Set
the engine once and every script in this package follows.

```bash
sudo dnf install -y podman            # or: sudo apt install -y podman
export AI_BOX_ENGINE=podman       # put this in ~/.bashrc to make it the default

scripts/build.sh all
scripts/verify-isolation.sh ubuntu
ai-box -- claude
```

Three differences the scripts handle, listed because each one is a real failure that the
naive `alias docker=podman` walks straight into.

**User namespaces, and why `--userns=keep-id` is mandatory.** Rootless Podman runs the
container in a user namespace where *you* are container UID 0 and every other container
UID maps to a subordinate UID on the host. The image's `dev` user has your UID by build
argument, so without `keep-id` it lands on a subuid: `--cap-drop=ALL` is still there,
`no-new-privileges` is still there, every isolation check still passes, and every file
the agent writes into `/workspace` is owned by a number that is nobody on your host. That is
why `verify-isolation.sh` asserts the flag is present when the engine is podman rather
than leaving it to inspection.

**SELinux.** On Fedora and RHEL a bind mount carrying no label option is unreadable
inside the container, and the message is a bare "permission denied" that says nothing
about SELinux. `ai-box` appends `,z` to the bind mounts and `relabel=shared` to the
credential mount, but only when `selinuxenabled` reports the host is actually enforcing,
so nothing changes on a Debian or Ubuntu host. `z` is the shared label rather than the
private `Z` on purpose: your project directory usually belongs to other host processes
too, an editor or a build server, and the private label would take it away from them.

**Subordinate ID ranges.** Rootless Podman needs an entry for your user in `/etc/subuid`
and `/etc/subgid`. Most distributions create one when the account is created. If yours
did not, container start fails with a message about `newuidmap`:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate
```

`scripts/doctor.sh` checks for this and says so before you hit it.

Two smaller points. Podman's build uses Buildah, which ignores the `# syntax=` directive
at the top of each Dockerfile; nothing in these Dockerfiles needs a BuildKit-only
feature, so they build either way. And `--memory`, `--cpus` and `--pids-limit` need
cgroups v2 with delegation, the default on any current distribution; if Podman warns
that it is ignoring them, those limits are advisory on that host and the isolation
itself is unaffected.

If you would rather not set the variable, `podman-docker` (or a `docker` symlink to
`podman` on your `PATH`) works too, but then nothing adds `keep-id` for you. Put
`userns = "keep-id"` in the `[containers]` section of
`~/.config/containers/containers.conf` if you go that way. `AI_BOX_ENGINE` is the
supported path.

---

## 1. Threat model - what this does and does not buy you

**It does prevent:** the agent (or anything it compiles and runs, or any package it
pulls from npm/PyPI/crates) from reading or modifying files outside the one directory
you mounted; from reading your SSH keys, cloud credentials, shell history, or other
repositories; from persisting anything on the host outside the mounted paths; from
touching the host's systemd, cron, or package database.

**It does not prevent:** a Linux kernel exploit from escaping the container; data
exfiltration over the network (the container has full outbound access unless you
restrict it - see §8); or damage to the project directory you deliberately mounted.
That directory is fully writable, so keep it in git and push often.

**Rules that matter more than any flag below:**

1. Never mount `$HOME`, `/`, or a parent directory of many projects. One project, one
   mount.
2. Never mount `/var/run/docker.sock`. That is a direct, trivially exploitable path to
   host root.
3. Never run the container with `--privileged` or `--network host`.
4. Never bake a key into the image. Image layers are readable by anyone who gets the
   image, and `docker history` shows build args.

---

## 2. Host directory layout

`scripts/install.sh` creates these for you; here is what they are:

```
~/.aikeys/                   credential store, mode 0700
    default.key                  one profile per file, mode 0600
    projects/<dirname>           pins a project to a profile NAME
~/.config/ai-box/            legacy env-file secrets, mode 0700
    anthropic.env                API key, mode 0600 (only for -a envfile; you
                                 create this by hand, install.sh does not seed
                                 it with a placeholder any more)
~/.local/share/ai-box/       per-image persistent state, mode 0700
    ai-ubuntu_26.04/
        claude/                  -> /home/dev/.claude   (CLAUDE_CONFIG_DIR: .claude.json,
                                 credentials, sessions, settings, backups)
        ccache/                  -> /home/dev/.cache/ccache
    ai-fedora_44/            same, kept separate on purpose
~/src/ai-box-v2.3.8/     this package (Dockerfiles, scripts, docs)
```

State is keyed by image reference, so the Ubuntu and Fedora boxes never share a ccache,
and a base-OS upgrade starts with a clean one. Run:

```bash
scripts/install.sh
```

## 3. Build the images

```bash
cd ~/src/ai-box-v2.3.8

scripts/build.sh all            # all three images, with all pending OS updates
scripts/build.sh ubuntu         # or one at a time
scripts/build.sh --no-updates all           # packages exactly as the base tag shipped
scripts/build.sh --no-updates -t 26.04.1 all  # reproducible rebuild of a known image
scripts/build.sh -g 16 ubuntu   # make unversioned gcc/g++ be GCC 16
scripts/build.sh -L -l 22 ubuntu  # Clang from apt.llvm.org instead of the archive
scripts/build.sh -C latest all  # track the latest Claude Code channel
```

The Ubuntu image is Ubuntu 26.04 LTS. Everything in it comes from Ubuntu's signed
archive: GCC 15.2 as `gcc`/`g++`, GCC 16 alongside it as `g++-16`, and Clang 21 as
`clang++`. Earlier versions of this package pulled Clang from apt.llvm.org because
24.04 only shipped Clang 18; on 26.04 that is no longer necessary, which removes a
third-party signing key and the most common build failure.

By hand, if you prefer. Note the context is the package root, because every Dockerfile
`COPY` from `shared/`:

```bash
docker build -f docker-ubuntu/Dockerfile.ai-ubuntu \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  --build-arg GCC_DEFAULT=15 --build-arg CLAUDE_CHANNEL=stable \
  -t ai-ubuntu:26.04 .

docker build -f docker-fedora/Dockerfile.ai-fedora44 \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  --build-arg CLAUDE_CHANNEL=stable \
  -t ai-fedora:44 .
```

`UID`/`GID` matter: they make files the agent creates in the bind mount owned by you
on the host, with no `chown` dance afterwards.

### Fresh by default, reproducible on request

Every build applies pending distro updates and pulls a fresh base image unless you say
otherwise. This is the right default for a long-lived dev image: the alternative is an
image that keeps whatever CVEs the base tag shipped with, forever, because Docker
happily reuses a cached upgrade layer. The build stamps the current date into that layer
so the cache cannot defeat the intent.

`--no-updates` gives that up deliberately, in exchange for a build that produces the
same packages every time. Pair it with `--os-tag` and a pinned `--claude-version` when
you need to reconstruct a specific historical image - reproducing a bug, or matching
what shipped a release. `--os-tag` accepts a plain tag, a point release, or a digest.

Which mode built an image is recorded in its labels:

```bash
docker inspect ai-ubuntu:26.04 \
  --format '{{index .Config.Labels "com.ai-box.os-updates"}} {{index .Config.Labels "com.ai-box.update-stamp"}}'
```

`build.sh` tags each result three ways: the moving tag (`ai-ubuntu:26.04`), the
agent-pinned tag (`ai-ubuntu:26.04-cc2.1.211`), and the package-pinned tag
(`ai-ubuntu:26.04-pkg1.6.1`). Verify:

```bash
docker run --rm ai-fedora:44 cat /etc/toolchain-versions
scripts/verify-isolation.sh ubuntu
scripts/verify-isolation.sh fedora
```

### Pinning for reproducibility

The Dockerfiles accept `--build-arg CLAUDE_VERSION=2.1.211` and use the `stable`
channel by default. Package-manager installs of Claude Code do not auto-update, and
`DISABLE_AUTOUPDATER=1` is set in the image, so the agent version is fixed by the image
tag. See `docs/upgrading.md` for the full upgrade and rollback story.

---

## 4. Credentials - how to store and supply the key

Credentials have their own document now, **`docs/credentials.md`**, because the
browser-free paths deserve more room than a section. The essentials:

- Keys live on the host in `~/.aikeys` (0700), one file per profile (0600), and are
  bind-mounted read-only into the container at `/run/secrets/ai-key`. A mounted file
  stays out of `docker inspect` and out of the host process list, unlike `-e`/`--env`.
- `ai-keys add <profile>` reads the key from the terminal with echo off. Nothing is
  ever baked into an image layer or a build arg.
- The profile's `kind:` decides which variable is exported - `api` →
  `ANTHROPIC_API_KEY`, `oauth` → `CLAUDE_CODE_OAUTH_TOKEN`, `bearer` →
  `ANTHROPIC_AUTH_TOKEN`. This matters: Claude Code's precedence means the wrong
  variable silently outranks the right credential.
- Per-project keys come from `ai-keys link` or a `.ai-profile` file in the repo
  that names a profile. The key itself must never live in the project directory, and
  `ai-box` refuses it if it does.
- A Console API key needs no browser at any point. Subscription users can borrow a
  browser once with `claude setup-token` and carry the resulting year-long token to a
  headless machine.

```bash
ai-keys init && ai-keys add default
ai-box -- claude              # auto-resolves a profile
ai-box -k work -- claude      # a specific one
ai-box -a login -- claude     # ignore the store, use the browser flow
ai-box -a pass -- claude      # GPG-backed via pass, shredded on exit
```

---

## 5. The `ai-box` wrapper script

The wrapper is shipped as `scripts/ai-box` and put on your PATH by
`scripts/install.sh`. It resolves the project directory, refuses a mount that
would widen the surface, creates the per-image state directory, wires up whichever
credential path you chose, and applies the hardening flags.

```
usage: ai-box [-i ubuntu|fedora|REF] [-p DIR] [-a MODE] [-k PROFILE|PATH]
                  [-N NETWORK] [-d] [-u] [-n] [-- CMD ...]
```

Refused mounts: `$HOME`, `/`, `/home`, `/root`, `/etc`, `/usr`, `/var`, `/opt`, `/boot`,
`/proc`, `/sys`, `/dev`, `/srv`, `/mnt`, `/media`; the credential store `~/.aikeys`;
ai-box's own state directory; and anything at or below `~/.ssh`, `~/.gnupg`,
`~/.aws`, `~/.kube`, `~/.docker`, `~/.config`, `~/.local`. Mounting one of those by hand
would quietly falsify the promise this package makes, so it is refused rather than
warned about.

`-n` prints the exact `docker run` argv, one word per line, and exits without running
anything. That is what `scripts/verify-isolation.sh` asserts against, so a regression in
the flags below cannot pass the isolation checks.

The run it performs, in full:

```bash
docker run --rm -it --init \
  --hostname ai-box-ubuntu \
  --user "$(id -u):$(id -g)" \
  --cap-drop=ALL --security-opt no-new-privileges \
  --pids-limit 8192 --memory 12g --cpus "$(nproc)" \
  --workdir /workspace \
  --volume "$PROJECT_DIR:/workspace" \
  --volume "$STATE/claude:/home/dev/.claude" \
  --env CLAUDE_CONFIG_DIR=/home/dev/.claude \
  --volume "$STATE/ccache:/home/dev/.cache/ccache" \
  --tmpfs /tmp:rw,nosuid,nodev,exec,size=4g \
  ai-ubuntu:26.04 "$@"
```

Every flag earns its place: `--user` keeps files in the bind mount owned by you,
`--cap-drop=ALL` removes every Linux capability, `no-new-privileges` blocks setuid
escalation, `--pids-limit` and `--memory` contain a runaway build, the `exec` tmpfs on
`/tmp` lets compiled test binaries run without touching the host, and `--init` reaps the
zombies that a long agent session inevitably produces.

Usage:

```bash
cd ~/src/cppwiki
ai-box                       # interactive shell in the Ubuntu image
ai-box -i fedora             # Fedora 44 toolchain
ai-box -- claude             # drop straight into the agent
ai-box -i fedora -d          # gdb/valgrind-capable session
ai-box -a pass -- claude     # API key from pass
ai-box -N none -- make       # build with no network at all
AI_BOX_MEMORY=24g ai-box
```

Overridable environment: `AI_BOX_IMAGE`, `AI_BOX_AUTH`, `AI_BOX_MEMORY`,
`AI_BOX_CPUS`, `AI_BOX_STATE`, `AI_BOX_CONFIG`, `AI_BOX_PASS_ENTRY`,
`AI_BOX_PASS_KIND`.

Inside the container:

```bash
claude                                  # normal, prompts for permission
claude --dangerously-skip-permissions   # see below
```

### On `--dangerously-skip-permissions`

This is the reason to containerize. Inside a box whose only writable host path is one
project directory, the flag is a reasonable trade: you lose the per-action prompts, and
the worst outcome is a mangled working tree you restore with `git checkout`. It is still
a bad idea on a machine with network access to internal systems, and it does not make
the agent's outbound network traffic safe. Combine it with §8 if that matters to you.

---

## 6. Optional: `docker compose` instead of the wrapper

`shared/compose.yaml` covers the same ground for people who prefer compose. Run it from
the package root so the build context is right:

```bash
export UID GID="$(id -g)" PROJECT_DIR=~/src/cppwiki
docker compose -f shared/compose.yaml run --rm fedora
```

It does not stage or shred a `pass`-backed secret; for that credential path use
`ai-box -a pass`.

---

## 7. The compiler: what lives where, and what persists

**The toolchain lives in the image, not in a volume.** That is deliberate - the image
tag is the toolchain version, so `ai-ubuntu:26.04-llvm21` is a reproducible
statement about which compiler built your artifacts. To change compilers, edit the
Dockerfile and rebuild; do not `apt install` inside a running container, because the
next `--rm` throws it away and the state stops being reproducible.

Three things you *do* want to persist across container lifetimes:

| What | Where in container | Backed by |
|---|---|---|
| ccache | `/home/dev/.cache/ccache` | `~/.local/share/ai-box/<img>/ccache` |
| Agent config, sessions, credentials | `/home/dev/.claude` (`CLAUDE_CONFIG_DIR`) | `~/.local/share/ai-box/<image>/claude` |
| ccache | `/workspace/.ccache-<image>` | the project directory itself |
| pip, uv and other XDG caches | `/workspace/.cache-<image>` | the project directory itself |
| Build tree | `/workspace/build` | the project directory itself |
| Custom toolchains | `/opt/toolchains` | the `ai-toolchains` named volume, if created |

ccache is preconfigured in all three images (`CCACHE_DIR`, `CCACHE_MAXSIZE=2G`, and
`CMAKE_{C,CXX}_COMPILER_LAUNCHER=ccache`), so a warm cache carries over between
sessions:

```bash
ccache -s                        # inside the container
ccache -M 20G                    # raise the ceiling; persists in the volume
```

**Why `CLAUDE_CONFIG_DIR` rather than mounting `.claude.json`.** Claude Code writes
`.claude.json` beside `~/.claude`. Bind-mounting a single *file* into a container is a
trap: the mount pins that inode, so a writer that replaces the file with `rename()` - the normal way to write a config atomically - fails, and a writer that truncates and
rewrites in place leaves a partial file if it is interrupted. Both end at
`JSON Parse error: Unexpected EOF` on the next start. Setting `CLAUDE_CONFIG_DIR` to the
directory that is already mounted moves the file inside it, where rename works normally
and no single-file mount exists. `ai-box` also validates the file before each run
and, if it is empty or truncated, backs it up and starts fresh rather than dropping you
at a "Reset with default configuration" prompt.

**Keep build trees per image and per compiler.** Ubuntu-Clang-21, Ubuntu-GCC-16 and the
Fedora toolchain must not share a directory:

```bash
cmake -S . -B build/ubuntu-clang21 -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_CXX_COMPILER=clang++
cmake --build build/ubuntu-clang21 -j"$(nproc)"

cmake -S . -B build/ubuntu-gcc16 -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_CXX_COMPILER=g++-16
cmake --build build/ubuntu-gcc16 -j"$(nproc)"
```

Add `build/` to `.gitignore` and, if you use one, to `.dockerignore`.

**A custom or hand-built toolchain** (a GCC trunk build, an experimental LLVM) goes in
a named volume mounted at `/opt/toolchains`, which is already on `PATH` in all three images:

```bash
docker volume create ai-toolchains
docker run --rm -it -v ai-toolchains:/opt/toolchains ai-fedora:44 bash
# build/install into /opt/toolchains/gcc-trunk, then symlink into /opt/toolchains/bin
```

`ai-box` mounts that volume automatically whenever it exists, so nothing else to
configure. This keeps a multi-gigabyte toolchain out of every image layer while staying
available to all three images. Remove it with `docker volume rm ai-toolchains`.

**Debugging:** `--cap-drop=ALL` plus the default seccomp profile will block `ptrace` on
some kernels, so gdb and valgrind fail with permission errors. Use `ai-box -d`,
which adds `--cap-add=SYS_PTRACE --security-opt seccomp=unconfined`. Do that only for
debugging sessions, not as the default. `perf` needs more than that and is best run on
the host: the Fedora image ships the `perf` binary, and the Ubuntu image cannot, because
on Debian and Ubuntu the binary lives in the kernel-matched `linux-tools-$(uname -r)`
package rather than in `linux-tools-common`.

---

## 7a. Static linking

All three images can link fully static C++ executables. The build asserts it, and
`smoke-test.sh` re-checks it against the built image, because the runtime archives come
from separate packages on rpm distributions and their absence surfaces as
`cannot find -lc` at a user's first attempt rather than at build time.

```bash
g++ -std=c++23 -static main.cpp -o app          # fully static
g++ -static-libstdc++ -static-libgcc main.cpp -o app   # usually what you want
```

What each image carries: `libc.a` and `libm.a` (from `glibc-static` on Fedora and Rocky,
from `libc6-dev` on Ubuntu), `libstdc++.a` and `libgcc.a`, and optionally `zlib` and
`openssl` static archives. Verify per image with `scripts/capabilities.sh` or by looking:

```bash
ai-box -- bash -lc 'ls /usr/lib*/libc.a /usr/lib/gcc/*/*/libstdc++.a 2>/dev/null'
```

### The caveat that matters

A fully static glibc binary is **not portable in the way people expect**, and the linker
says so:

```
warning: Using 'gethostbyname' in statically linked applications requires at runtime
the shared libraries from the glibc version used for linking
```

That is glibc's Name Service Switch: `gethostbyname`, `getaddrinfo`, `getpwnam` and
friends `dlopen` NSS modules at run time. A statically linked binary still needs those
shared objects present, from a matching glibc, so "static" does not mean "runs anywhere".
If the program does no name or user lookup, it is genuinely self-contained.

Three honest options, in order of how often they are the right one:

1. **`-static-libstdc++ -static-libgcc`.** Links the C++ runtime statically and leaves
   glibc dynamic. This is what most people actually want: it removes the libstdc++ version
   coupling that breaks binaries across distributions, and keeps NSS working. It needs no
   extra packages and works in every image already.
2. **`-static` with no name lookups.** Fine for compute-only binaries, and the warning does
   not appear if the symbols are not referenced.
3. **musl** for a genuinely portable static binary. `musl-gcc` is in the optional set on
   Ubuntu and Fedora; it has no NSS problem because it does not use NSS. The cost is a
   different libc, so anything depending on glibc extensions needs checking. It is a C
   toolchain: static C++ against musl needs a musl-targeted libstdc++, which these images
   do not ship.

For a distributable Linux binary, option 1 plus a modest glibc baseline is the usual
answer, and option 3 is the one to reach for when the target machine is genuinely unknown.

## 8. Restricting outbound network access (optional, recommended)

Isolation of the filesystem does not stop exfiltration. If you want a default-deny
egress policy, put an allowlisting HTTP proxy on a private Docker network and give the
container no other route.

Claude Code needs these hosts:

| Host | Why |
|---|---|
| `api.anthropic.com` | API requests, feature flags, WebFetch safety check |
| `claude.ai`, `claude.com`, `platform.claude.com` | login / OAuth token exchange and refresh |
| `downloads.claude.ai` | plugin downloads, update checks |
| `mcp-proxy.anthropic.com` | claude.ai MCP connectors (skip if unused) |
| `raw.githubusercontent.com` | `/release-notes` changelog |
| `storage.googleapis.com` | plugin metadata |

Plus whatever your build needs: `github.com`, `registry.npmjs.org`, `pypi.org`,
`crates.io`, `archive.ubuntu.com` … Set `DISABLE_TELEMETRY=1` and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` to drop the two Datadog intake hosts.

Sketch with tinyproxy:

A starting allowlist is in `shared/tinyproxy.conf.example`:

```bash
docker network create --internal ai-net       # no default route out
docker network create ai-egress               # proxy's own uplink

docker run -d --name ai-proxy --network ai-net \
  -v "$PWD/shared/tinyproxy.conf.example:/etc/tinyproxy/tinyproxy.conf:ro" \
  vimagick/tinyproxy
docker network connect ai-egress ai-proxy

# then run the box on the internal network, pointed at the proxy:
ai-box -N ai-net -- env \
  HTTPS_PROXY=http://ai-proxy:8888 \
  HTTP_PROXY=http://ai-proxy:8888 \
  NO_PROXY=localhost,127.0.0.1 claude
```

Claude Code honors `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` but **does not support SOCKS
proxies**. If you TLS-inspect, point `NODE_EXTRA_CA_CERTS` at your CA bundle inside the
container.

Simplest fallback when you only need to compile and read code: `--network none`. Claude
Code will not run without network, but a build-only container works fine that way.

---

## 9. Verify the isolation

```bash
scripts/verify-isolation.sh ubuntu
scripts/verify-isolation.sh fedora
```

It runs in three parts.

**The flags ai-box would actually use.** It reads `ai-box -n` and asserts on that
argv: `--cap-drop=ALL` is present, `no-new-privileges` is present, `--user` matches the
caller, `--privileged` and `seccomp=unconfined` are absent, every bind source is either
the project directory or the per-image state directory, and no forbidden path
(`/var/run/docker.sock`, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.aikeys`) appears
anywhere in the command. This script once rebuilt the flags itself, which meant
the wrapper could have dropped every one of them and the checks would still have passed.

**What the container can do.** With a throwaway temp directory at `/workspace`: the process is
not root, `sudo` is absent, there is no Docker socket, there are no SSH keys, the
effective capability set is empty, `no_new_privs` is set, `/etc` and `/usr/local/bin` are
not writable, `/workspace` is writable, `claude` is present, and the file it created in
`/workspace` is owned by your host UID/GID. It also prints every host filesystem visible from
inside, which should be `/workspace` and nothing else.

**That `-N none` means what it says.** A container on `--network none` must fail to
resolve `api.anthropic.com`.

Non-zero exit means something regressed.

To poke around by hand:

```bash
ai-box -a none -- bash -lc 'ls /; ls ~; findmnt -no TARGET,SOURCE -t ext4,xfs,btrfs'
```

---

## 9a. Smoke-test the toolchain

Isolation is one half; the other is that the image can actually build something.

```bash
scripts/smoke-test.sh ubuntu
scripts/smoke-test.sh fedora
```

It mounts `examples/` read-only at `/workspace`, with the same hardening flags the
wrapper uses, and checks that `claude` runs, that `/etc/toolchain-versions` is
populated, and that every compiler in the image compiles **and runs** a C++23
program. It then builds the two C++26 static reflection programs in `examples/`
with any compiler that defines `__cpp_impl_reflection`.

Reflection (P2996) is GCC-only at the time of writing and needs `-freflection`.
Measured on Fedora 44 with GCC 16.1.1: `__cpp_impl_reflection = 202603`,
`__cpp_lib_reflection = 202603`, `__cpp_expansion_statements = 202506`. The same
Fedora's Clang 22.1.8 rejects the programs outright, and the Ubuntu image's GCC
16 is a snapshot branch that is not the default compiler. So the reflection
checks report SKIP rather than FAIL when a compiler does not have the feature.
`examples/README.md` covers the API and the three rules that are easy to trip
over. Nothing in `examples/` is COPYed into an image; it is mounted at run time
like any other project.

The same script checks the Python environment: that `python` resolves to
`/opt/venv/bin/python` rather than the system interpreter, that `sys.prefix`
agrees, that `pip`, `uv`, `ruff`, `mypy` and `pytest` all run, that
site-packages is writable without root, and that `pytest` executes a test.
Writability is tested by touching a file rather than by installing a package, so
the check does not quietly depend on PyPI being reachable.

---

## 9b. Python inside the image

All three images carry a virtualenv at `/opt/venv`, first on `PATH` and owned by the
unprivileged user. `python`, `pip`, `uv`, `ruff`, `mypy` and `pytest` are there
and `pip install` works in a session without root.

The reason it is a venv rather than the system interpreter is PEP 668: both
Ubuntu 26.04 and Fedora 44 mark their system Python as externally managed, so
`pip install` into it is refused. The usual workaround, `--break-system-packages`,
does exactly what its name says and would put agent-installed packages where the
distro's own tooling expects to be authoritative. A venv avoids the question
entirely.

```bash
ai-box -- python -c 'import sys; print(sys.prefix)'   # /opt/venv
ai-box -- pip install requests                        # works, and is ephemeral
ai-box -- uv venv --python 3.13 /tmp/py313            # a different interpreter
```

Anything installed at run time disappears with the container, which is the
point: the image stays reproducible and two people running the same tag get the
same environment. To make an addition permanent, put it in the build:

```bash
scripts/build.sh --python-tools "uv ruff mypy pytest pandas numpy scipy" all
scripts/build.sh --uv-python 3.13 ubuntu     # also bake in a standalone 3.13
```

`/opt/venv` is inside the image, not a mount. Nothing about it reaches the host,
and `pip install` in the container cannot touch a host Python.

---

## 10. Stronger isolation (when the default is not enough)

**Rootless Docker** - removes the docker-group-equals-root problem entirely. The daemon
runs as you, in a user namespace; container root maps to an unprivileged host uid.

```bash
sudo apt install -y uidmap dbus-user-session
dockerd-rootless-setuptool.sh install
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
systemctl --user enable --now docker
```

Everything in this document works unchanged. Caveat: with rootless Docker the in-image
`UID`/`GID` mapping shifts - build with `--build-arg UID=1000 --build-arg GID=1000`
and drop `--user` from the wrapper, since rootless already maps container uid 1000 to
your host uid.

**userns-remap** (rootful daemon, remapped containers) - add to
`/etc/docker/daemon.json`:

```json
{ "userns-remap": "default" }
```

Then `sudo systemctl restart docker`. Note this changes bind-mount ownership semantics;
you will need `chown` on the state dirs to the subuid range.

**Read-only root filesystem** - the images tolerate it if you supply writable tmpfs for
the paths that need it:

```bash
--read-only \
--tmpfs /tmp:rw,nosuid,nodev,exec,size=4g \
--tmpfs /run:rw,nosuid,nodev,size=64m \
--tmpfs /home/dev/.cache:rw,size=1g
```

**Rootless Podman** - the same benefit as rootless Docker with no daemon at all, and the
one this package supports directly rather than as a documented deviation. See §0a;
`AI_BOX_ENGINE=podman` is the whole change, and `--userns=keep-id` keeps the
bind-mount ownership semantics identical to rootful Docker rather than shifting them the
way the two options above do.

**gVisor** (`--runtime=runsc`) or a Firecracker/Kata VM runtime if kernel-level escape
is in your threat model. Overkill for a laptop, standard practice for CI that runs
untrusted agent output.

---

## 11. Git, SSH, and the outside world

Do **not** mount `~/.ssh` or `~/.gitconfig`. `~/.gitconfig` frequently references
`credential.helper store`, which points at `~/.git-credentials` in cleartext, and an
agent with your SSH agent socket can push anywhere you can.

Workable patterns, in order of preference:

1. **Commit inside, push outside.** Let the agent commit locally in `/workspace`; run
   `git push` from the host. Zero credentials in the container.
2. **A dedicated deploy key** with write access to exactly one repository, mounted
   read-only: `-v ~/.config/ai-box/deploy_ed25519:/home/dev/.ssh/id_ed25519:ro`.
3. **A fine-grained GitHub PAT** scoped to one repo, in the env file, used over HTTPS.

Give the container an identity so commits are attributable:

```bash
# inside the container, once - persists via the .claude state volume only if you
# put it in the project instead:
git config user.name  "Erez Strauss (ai-box)"
git config user.email "you@example.com"
```

---

## 11a. Skills, subagents, MCP servers, and hooks

Everything else in this document describes what the *container* can reach. This
section describes what the *agent's own configuration* can do inside it, which is
a different question and one the rest of the documentation was silent about.

### Where each thing lives, and what survives

| What | Path inside the container | Survives the container? | Travels with the repo? |
|---|---|---|---|
| project skills | `/workspace/.claude/skills/` | yes, it is the host project directory | yes |
| project subagents | `/workspace/.claude/agents/` | yes | yes |
| project settings and hooks | `/workspace/.claude/settings.json` | yes | yes |
| user skills | `~/.claude/skills/` | yes, in the per-image state directory | no |
| user settings | `~/.claude/settings.json` | yes, same place | no |
| MCP server config | either, depending on scope | follows whichever it is in | only if project-scoped |

The split matters and is easy to get wrong. Anything under `/workspace/.claude` is
in your repository and is shared with everyone who clones it. Anything under
`~/.claude` is in `~/.local/share/ai-box/<image>/claude/` on the host, is
private to you, and is **separate per image**: a skill added while working in the
Ubuntu box is not there in the Fedora one.

### The consequence that is not obvious

`/workspace/.claude/` is writable by the agent. That is by design: the whole point
of the box is that the agent can write freely inside it, including writing its own
skills, subagents and hooks. Inside the container that is contained, and it is
exactly the trade this package exists to make safe.

**The boundary does not follow the directory home.** If you later run Claude Code on
that same project directory *on your host*, outside the box, you inherit whatever
the agent wrote there, and a hook in `settings.json` is a shell command that runs on
your machine with your permissions. Nothing about the container prevents this,
because the container is no longer involved.

The mitigation is one line, and it is worth making a habit after any unattended
session:

```bash
git status --short .claude/ && git diff .claude/
```

Current Claude Code versions do prompt before running hooks it has not seen before,
so this is a caution rather than a known exploit. Treat it the way you would treat
any executable content that arrived in a repository: read it before you run it
outside the sandbox that was containing it.

### What an MCP server actually adds

An MCP server is worth reasoning about concretely rather than by reputation.

A **stdio** server is a subprocess of the agent. It runs inside the container, as
the same unprivileged user, with the same dropped capabilities, and it can reach
exactly what the container can reach: `/workspace`, the tmpfs, and the network. It
does not widen the boundary.

That has two consequences worth stating:

- A **filesystem MCP server pointed at `/workspace`** adds nothing to the agent's
  reach, because `/workspace` is already the only host directory mounted. One
  pointed anywhere else is not a risk either, for the same reason: there is nothing
  else there to serve.
- A server that **fetches or posts over the network** does not escape the container,
  but it does move data, and outbound traffic is the axis this package does not
  restrict by default. If that matters, restrict egress first (section 8) and add
  the server second, not the other way round.

An **HTTP or SSE** server configured to a URL on your host is different: it reaches
out of the container to something running on your machine, which is a hole you are
opening deliberately. `--network none` closes it, and so does an egress allowlist.

Anything that needs a credential of its own, a GitHub token for example, brings the
question this package answers for the Anthropic key back again: where does that
secret live, and is it visible in `docker inspect`? Mount it as a read-only file,
as `ai-box` does, rather than passing `--env`.

### Skills and subagents

Both are content in a directory that the agent reads and acts on, which means both
are a way for a repository to influence what runs. A skill is markdown plus,
optionally, scripts it tells the agent to run. A subagent is a prompt with a tool
allowlist.

Inside the box that is fine, and it is useful: a skill that encodes "build with
every compiler in this image and run the tests" is worth more here than in most
environments, because the toolchain is fixed and known. The caution is the same as
above and has the same one-line mitigation: know what arrived in `.claude/` from a
clone before you run anything outside the container.

This package deliberately ships no skill, subagent or MCP server catalogue. Those
churn fast, a curated list implies an endorsement this project cannot back, and
adding a network-facing component to the default path is a decision this project
requires be made deliberately rather than by copying a README.

---

## 12. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `configuration file at /home/dev/.claude.json is corrupted: JSON Parse error: Unexpected EOF` | Fixed in v1.3.2. Older versions bind-mounted that single file, which cannot be replaced by `rename()`, so writes were non-atomic and an interrupted one left it truncated; a fresh state directory also seeded it empty, and empty is not valid JSON. The wrapper now sets `CLAUDE_CONFIG_DIR` so the file lives inside the mounted directory, and repairs an invalid one at startup. If you hit it on an old version, pick "Reset with default configuration". |
| Files in `/workspace` owned by root on the host | Image built without matching `--build-arg UID/GID`, or `--user` omitted. Rebuild, then `sudo chown -R $(id -u):$(id -g) <project>`. |
| `detected dubious ownership in repository` | The entrypoint adds `safe.directory=/workspace`; if you mount elsewhere, add it manually. |
| dnf: `No match for argument: <pkg>` and `Failed to resolve the transaction` | A package name changed or was retired between Fedora releases. The accompanying `already installed` lines are informational noise, not the cause - look for the `No match` line. Convenience packages live in the optional group and are skipped automatically; if a *required* one breaks, correct the name in the Dockerfile. |
| `runs on the host, not inside the box` | You are running a host-side command from inside a container. Run it from the host checkout. Building or starting containers from inside would need the engine socket, which this project never mounts. |
| `container engine (docker) is ... not running` | `sudo systemctl start docker`. The message distinguishes a missing binary, a stopped daemon and a socket you cannot reach, because the fixes differ. |
| Told to try Podman, but then "image not built" | Podman keeps images in its own store, so an image built with Docker is invisible to it. Either rebuild with `AI_BOX_ENGINE=podman`, or copy them across while the Docker daemon is reachable: `podman pull docker-daemon:ai-fedora:44`. |
| A build flag seems to do nothing | `-g/--gcc`, `-L`, `-l` apply to the Ubuntu image only; the Fedora image uses whatever compilers Fedora ships. `build.sh` warns when you pass them with `fedora`. |
| `claude: command not found` | Package install failed at build time - usually a network block on `downloads.claude.ai`. Rebuild with `--progress=plain --no-cache` and read the log. |
| Login opens no browser | Expected. Claude Code prints a URL; open it on the host, paste the code back. |
| `Unable to connect to Anthropic services` behind a proxy | Set `HTTPS_PROXY` and `NODE_EXTRA_CA_CERTS` (§8). Run `claude doctor` inside the container for diagnostics. |
| gdb: `ptrace: Operation not permitted` | Use `ai-box -d`. |
| `upgrade.sh` reports "channel had nothing newer" every time | The agent install is a Docker layer, so an unchanged build reused it; only the daily OS-update stamp ever busted it, which made `--no-updates`, and any second upgrade on the same day, a silent no-op. `upgrade.sh` now resolves the channel candidate and passes it as `CLAUDE_VERSION`. |
| `-k/--keep-cache` implies `--no-updates`, because reusing the OS layers is only possible if nothing earlier in the Dockerfile changes, and it says so when you pass it. |
| Slow rebuilds after every session | The ccache volume is not mounted, or the build directory lives in the container instead of `/workspace`. |
| `llvm.sh` fails with no packages for the codename | Only reachable via `-L`; drop it and use the archive Clang, which is what the default build does. |
| `pip install` refuses with "externally managed environment" | Ubuntu 26.04 enforces PEP 668. Use `python3 -m venv`, or `pip install --break-system-packages` inside the container, where the blast radius is nil. |
| Out-of-memory during a big `-j` build | Raise `AI_BOX_MEMORY`, or build with `-j$(($(nproc)/2))`. The container memory limit is enforced by cgroups; the OOM killer inside the container is real. |

Inside the container, `claude doctor` prints installation and settings diagnostics
without starting a session - the first thing to run when something is off.

---

## 13. Maintenance

Upgrades have their own document, `docs/upgrading.md`, because there is
more to say than fits here. The short version:

```bash
scripts/check-updates.sh     # is there a newer Claude Code? (read-only)
scripts/upgrade.sh           # rebuild all three images, leaving :…-prev rollback tags
docker image prune -f
```

State that survives a rebuild: everything under `~/.local/share/ai-box` (OAuth token,
sessions, ccache) and any named volumes such as `ai-toolchains`. State that does not:
anything installed inside a running container. That asymmetry is the design.

---

## Quick reference

```bash
# once
scripts/install.sh
ai-keys init && ai-keys add default
scripts/build.sh all

# daily
cd ~/src/myproject && ai-box                     # Ubuntu/Clang shell
cd ~/src/myproject && ai-box -i fedora -- claude

# inside the box
claude --dangerously-skip-permissions
cmake -S . -B build/clang -DCMAKE_CXX_COMPILER=clang++ && cmake --build build/clang -j$(nproc)
ccache -s
cat /etc/toolchain-versions
claude doctor

# upkeep
scripts/check-updates.sh
scripts/upgrade.sh                              # agent + OS updates
scripts/build.sh --no-updates -t 26.04.1 all    # reproducible rebuild
scripts/verify-isolation.sh ubuntu
scripts/smoke-test.sh ubuntu
ai-keys check && ai-keys test
```

**See also:** `docs/credentials.md` for credentials,
`docs/upgrading.md` for keeping the agent current.

**Reference:** Claude Code setup and package repositories - <https://code.claude.com/docs/en/setup>; network allowlist - <https://code.claude.com/docs/en/network-config>.
