# Design decisions and open work

This file records the choices that shaped `ai-box`, with the reasoning, and what is still
open. It is written for someone deciding whether to change one of them. `CHANGELOG.md` has
the history; this file describes the present.

---

## Decisions

### D1. Caches live in the project directory, not in a side mount

`~/.cache` inside the container is a symlink to `/workspace/.cache-<image>`, and
`XDG_CACHE_HOME` and `CCACHE_DIR` point at the same place. Both mechanisms are used,
because tools divide into those that honour XDG and those that expand `~/.cache` literally.

**Why.** It removes a mount from the default surface, it makes a cache visibly belong to
the project that produced it, and deleting a project deletes its cache. The alternative, a
third bind mount from the state directory, meant caches outlived the projects that created
them and grew without anyone noticing.

**Costs, accepted.** Caches are no longer shared between projects, so the first build in
each project is cold, and `CCACHE_MAXSIZE` is 2G rather than 10G because the cache now
sits in a project rather than one shared store.

**Consequence to know about.** Running `ai-box` in any directory leaves `.cache-<image>`
and `.ccache-<image>` in it. Add both to a project's `.gitignore`. In this repository they
are in `.gitignore` and in `pack.sh`'s exclusion list, because a session run against a
checkout would otherwise block a release.

**Traps this created, all handled in the images.** A `VOLUME` declared at a path that is a
symlink into a bind mount creates an anonymous volume that shadows the target and silently
discards the cache. `mkdir -p ~/.cache/pip` through a dangling symlink fails with
`File exists`, so the entrypoint creates the targets before anything uses the link. A probe
container that bypasses the entrypoint must set the cache variables itself. An unwritable
workspace falls back to tmpfs.

### D2. The project mounts at `/workspace`

Not `/work`: long enough to be unambiguous in a prompt, and the convention most container
tooling and most agents already expect.

### D3. Three images, not one

Ubuntu 26.04 for an LTS target, Fedora for the newest compilers, Rocky 10 for a
RHEL-family production target. They are behaviourally identical from the wrapper's point of
view — same entrypoint, same user, same paths, same variable names — and
`scripts/check-image-parity.sh` enforces that mechanically, because as prose it did not
hold.

Rocky differs in one substantive way. RHEL pins a conservative system GCC for the life of a
release and ships newer compilers as Software Collections under `/opt/rh` that normally
require `scl enable`. The image probes for the newest `gcc-toolset` and `llvm-toolset` the
package manager can resolve, then puts them on `PATH` through a version-independent
`/opt/rh/toolset` symlink, so `gcc` is the toolset compiler and no command needs a wrapper.

### D3a. Newest obtainable per image; identical versions are not a goal

**The policy, in one sentence: each image ships the newest compilers it can obtain, not
merely the newest its distribution happens to package.**

That distinction is the whole point, and it has bitten this project twice. "Newest in the
Ubuntu archive" would give Clang 21 and GCC 15 while Fedora ships Clang 22 and GCC 16.1.
"Newest obtainable" gives Ubuntu GCC 16 (`gcc-16`, in the archive but not the default) and
Clang 22 (from apt.llvm.org, which the archive trails by a major version). On Rocky it
means a `gcc-toolset`, because RHEL pins a conservative system GCC for the life of a
release and ships newer compilers separately.

So in each image the unversioned `gcc`, `g++`, `clang` and `clang++` are the newest the
image could get, and no image is held back to match another. Where a distribution offers
several, older ones stay installed and reachable by their versioned names (`g++-15`).

**Sources counted as obtainable.** The distribution's own repositories; well-known
first-party upstream repositories for the compiler in question (apt.llvm.org for LLVM);
and RHEL's Software Collections. Not: unvetted PPAs, random tarballs, or anything without
a signature the build verifies.

**The escape hatch, and why it exists.** `--toolchain distro` restricts an image to its
distribution's own signed repositories. That is one fewer third-party signing key in the
build, at the cost of an older Clang. Some supply-chain policies require it; the default
does not assume yours does. `-g 15` similarly pins a specific GCC.

**Newest is not the same as most conservative, and there is now evidence.** A build of all
three images produced GCC 16.0.1 (a March snapshot) on Ubuntu and GCC 16.2.1 (a release) on
Fedora. A C++26 reflection program that compiles on Fedora failed on Ubuntu with
`odr-used inline variable is not defined`. Same major version, different behaviour, because
one is a trunk snapshot. If you need a released compiler, use the Fedora image or pin with
`-g 15`.

**Newest is not the same as most conservative, and that is accepted.** Ubuntu's `gcc-16`
is a snapshot of the GCC 16 branch, not a released 16.1. If a project needs a released
compiler, pin it (`-g 15`) or use the Fedora image, which currently carries a released
16.1.1. Being explicit about this beats quietly shipping the older one.

**Attempts degrade, they do not fail.** If apt.llvm.org has no packages for a codename
yet, the build falls back to the archive Clang and says so, rather than failing. An image
that cannot get the newest is still a working image.

**What parity does still mean.** Hard rule 10 is about the *contract*, not the versions:
same entrypoint, same unprivileged user, same paths (`/workspace`, `/opt/venv`,
`/opt/toolchains`), same environment variable names, same wrapper behaviour.
`scripts/check-image-parity.sh` enforces exactly that and deliberately says nothing about
which compilers are present. A common subset that works everywhere is a convenience, never
a requirement.

**Consequence.** Because the images differ by design, what each one actually contains has
to be discoverable rather than assumed. Every image writes `/etc/toolchain-versions` at
build time, and `scripts/capabilities.sh` collects those into one table. Read that rather
than inferring from the Dockerfiles.

### D4. Optional agents are off by default

Claude Code is always installed, from a signed repository with a fatal GPG fingerprint
check. Codex, Gemini and Grok are opt-in. Each additional agent is another binary with
network access, its own credential and its own update cadence, inside a container whose
purpose is a small blast radius. Of the three, only Codex ships a native Linux binary; the
others pull a Node runtime into an image that otherwise has none.

Vendors' `curl … | bash` installers are not used. Piping an unpinned remote script into a
shell during an image build is the thing this project exists to avoid.

### D5. `/opt/venv` carries a scientific stack, not only tooling

The virtualenv holds `uv`, `ruff`, `mypy`, `pytest`, `ipython`, `build` and `wheel`, and
also `jinja2`, `numpy` and `pandas`, costing roughly 150 MB per image.

**The argument against is real:** numpy has ABI consequences for anything building an
extension module, and that is a project decision rather than an image one.

**Why they stay.** `/opt/venv` is the tooling venv, and a project that cares about the ABI
creates its own virtualenv, which the documentation tells it to do and which overrides this
one. Having numpy present serves the common case — a one-off calculation, reading a CSV —
inside a container that may have restricted egress, without a first-run install.

Use `--python-tools` at build time if the trade does not suit you.

### D6. Credentials are files, and the profile's kind decides the variable

Keys live on the host in `~/.aikeys`, one file per profile, mounted read-only into the
container. Anything passed with `--env` appears in `docker inspect`; a mounted file does
not. A profile declares its `kind:`, which selects the environment variable to export,
because agents read different variables and exporting the wrong one silently outranks the
right credential.

One parser does this, shared by the host scripts and the container entrypoint. Three copies
once disagreed, and the disagreement presented as an unreproducible HTTP 401.

### D7. Configuration files are read, never sourced

`~/.config/ai-box/config` and the companion `.env` in a key profile are parsed with an
allowlist of names. A file that can execute code sits on the credential side of the
boundary, and one of them is mounted into every container.

### D8. OS updates are on by default

Every build applies pending distro updates and pulls a fresh base image. A build stamp goes
into a layer so the cache cannot quietly turn that promise into a no-op. `--no-updates`
exists for reproducibility, not speed: pair it with `--os-tag` and a pinned agent version to
reconstruct a specific image.

### D9. Podman is a first-class engine

One variable selects the engine. Rootless Podman needs `--userns=keep-id`, or every file the
agent writes lands with an unusable owner; SELinux relabelling is applied only when the host
actually enforces it. Aliasing `docker` to `podman` does not work.

### D10. The isolation check runs the real command

`verify-isolation.sh` parses what `ai-box -n` prints, and runs its probe container *through*
`ai-box`. Both halves therefore share one construction path. An earlier version rebuilt the
hardening flags itself, which meant it would have reported PASS on a wrapper that had lost
`--cap-drop=ALL`.

---

### D11. Other languages are opt-in, from distro packages only

`--lang rust,go` installs a language toolchain at build time. This is a change of position
worth recording, because "language breadth" was previously listed as out of scope.

**What changed.** Nothing about the identity: C++ and Python remain what this project does
properly, and competing on breadth with a project that has fifteen language profiles would
be competing badly. What changed is the recognition that a user who needs Rust will either
fork the Dockerfile or give up, and a supported seam is better than either.

**The limits are deliberate.** Distribution packages only, installed as optional leaves.
No upstream installers during a build: `curl https://sh.rustup.rs | sh` is the same
category as the agent vendors' installers, which this project refuses. That means the
toolchains lag upstream, sometimes considerably, and the documented answer is to install
rustup into the *project* at run time where it is the user's decision.

**A consequence for an earlier non-goal.** "No Node toolchain for project work" was listed
as not planned. `--lang node` makes it available on request, which is a narrowing of that
non-goal rather than a reversal: still not present by default, still not installed for the
agents' sake, but no longer refused when a user asks for it.

## Open work

Roughly in the order it should be done.

1. **Build all three images from a cold cache and run the full check set.** The script layer
   is exercised heavily; the images have not been built by every session that changed them.
   Until that happens, image-level claims are untested. Record the compiler versions that
   actually land, from `/etc/toolchain-versions`.
2. ~~**A project `CLAUDE.md` template**~~ **done**: `docs/project-template.md`. Worked
   example projects are still open. The smoke test now generates its own sources, so a
   future `examples/` would hold projects showing how to work in the box rather than
   compiler probes, which is what the directory should have been.
3. **Prove the optional agents on a built image.** Pinned versions, a fatal `--version`, a
   Codex checksum and a smoke-test branch that exercises whichever agents an image contains
   are all in place. What remains is running it against real images.

   One agent crash has been diagnosed and fixed. Gemini segfaulted at startup on the Fedora
   image, in `v8::internal::JSSegments::Create` reached from `Intl.Segmenter.prototype.segment`.
   The cause was in this project, not in the agent: these images install with
   `install_weak_deps=False`, which drops `nodejs-full-i18n`, and a distro Node without ICU
   break-iterator data returns a null `icu::BreakIterator*` that V8 dereferences —
   a native SIGSEGV with no JS stack and nothing to catch (nodejs/node#51752). The
   package is now named explicitly, and both `install-agents.sh` and `smoke-test.sh`
   assert that `Intl.Segmenter` actually works.
4. **Egress allowlist covering the optional agents.** The proxy example covers Anthropic and
   the common package registries; Google and xAI endpoints are absent, so it is incomplete
   for anyone building with `--agents all`.
5. **Sanitizer and `/opt/toolchains` documentation**, after testing ASan on these images.
6. ~~**Fill the gaps that are gaps, not differences.**~~ **Done.** Rocky now carries Clang
   21.1.8 from its base repositories; the extra attempt added for that image worked. The
   remaining spread is a version difference, which D3a says is expected:
   Clang 22.1.8 on Ubuntu and Fedora, 21.1.8 on Rocky.

7. **Old item, kept for reference.** Rocky carries Clang from the base repositories,
   where the other two have 21 and 22. Under D3a a version difference is fine, but the
   complete absence of a compiler the other images have is worth one more attempt: check
   whether `llvm-toolset` is resolvable on Rocky 10 with CRB enabled, and if it genuinely
   is not, say so in the image table rather than leaving it to be discovered.
   `scripts/capabilities.sh` makes the difference visible either way.

## Explicitly not planned

A fourth distribution. MCP servers by default. An egress filter enabled by default inside
the agent's own container. A Node toolchain for project work, as opposed to as an agent
runtime. Auto-installing dependencies from a project manifest at container start.

Each of these either widens the mount surface, adds a network path, or moves data, so each
is a discussion before it is a patch.
