# AGENTS.md - working agreement for this package

*The canonical working agreement, for any agent working on ai-box itself -- Claude, Codex,
Gemini, Grok -- and for humans. `CLAUDE.md` exists because Claude Code reads that exact
filename, and points here. `README.md` describes what the package is and how to use it;
this file describes how to change it.*

It describes the rules that must not be broken and what "done" means. If you are here to
*use* ai-box rather than to change it, read `README.md` instead. If you are opening a
project inside the box, copy `docs/project-template.md` into that project.

## What this is

`ai-box` builds three Docker images (Ubuntu 26.04 LTS, Fedora 44 and Rocky Linux 10) that contain a
C++ build environment plus Claude Code, and a wrapper script that runs them with exactly
one host directory mounted. The product is a **security boundary**. Every change is
judged first on whether it preserves that boundary, and only second on convenience.

Current version: see `VERSION` (single source of truth - never hardcode it elsewhere).

## Read these before proposing work

This file is loaded automatically at the start of every session. Nothing else is, so
anything a previous session decided lives in one of these and has to be opened
deliberately:

| File | What it carries forward |
|---|---|
| `docs/design-decisions.md` | **Decisions already taken (section 0), and what the next releases are for.** Read this first. A decision recorded there is settled; reopen it only with a reason, and edit the entry rather than dropping it. |
| `CHANGELOG.md` | Every release and the reasoning behind it, not just what changed. |
| `CHANGELOG.md` | What 1.6.0 merged from two divergent branches. Read before assuming a piece of this codebase is redundant; several things that look duplicated are load-bearing. |
| `git log` (only in a checkout; the released tarball has no `.git`, so `CHANGELOG.md` is the durable record) | Commit messages here are written to explain why, at length, on purpose. |

If this session decides something that a future session would otherwise re-argue,
write it into `docs/design-decisions.md` section 0 before finishing. That is the mechanism; there
is no other.

## Layout and where things belong

| Path | Contents | Rule |
|---|---|---|
| `docker-ubuntu/`, `docker-fedora/`, `docker-rocky/` | one Dockerfile each | distro-specific logic only |
| `shared/` | files `COPY`ed into **every** image, plus config templates | anything duplicated between Dockerfiles belongs here instead |
| `scripts/` | host-side bash | every script sources `lib-common.sh`; no logic duplicated across scripts |
| `examples/` | C++ programs the smoke test compiles | must build with the image's own compilers, or be skipped by a documented feature probe |
| `docs/` | operator documentation | versioned filenames (`*-v1.md`) |
| `.github/` | workflows, issue templates, dependabot | repository infrastructure, never shipped in the release archive |

Every file in the package has a row in the `README.md` inventory explaining what it
is and why it exists. Adding a file means adding its row in the same change;
`scripts/check-file-inventory.sh` makes forgetting a failed build rather than a slow
decay into an undocumented tree.

The Docker build context is the **package root** (every Dockerfile `COPY`s from `shared/`).
Never change a Dockerfile to assume its own directory is the context.

## Hard rules

These are not preferences. Violating one is a defect, regardless of how well the change
otherwise works.

1. **No secrets in images.** Never add `ENV ANTHROPIC_API_KEY`, never take a key as a
   `--build-arg`, never write a key into a file that a `COPY` could pick up. Credentials
   arrive at run time only: a read-only file mount from `~/.aikeys`, a `pass`-staged
   mount, or an OAuth token in the state directory.
   Corollaries that are equally binding:
   - Never accept a key as a command-line argument in any script; it leaks into shell
     history and `ps`. Read it from a terminal with echo off, or from a file.
   - Never print a key. `ai-keys` prints fingerprints (last 4 + short hash) instead.
   - `ai-box` must keep refusing a key file located inside the mounted project
     directory. That directory is agent-writable and git-adjacent.
   - Prefer a mounted file over `-e`/`--env`: env values show up in `docker inspect`.
2. **No sudo, no capabilities, no privilege escalation path** in any image. If a task
   seems to need root inside the container, the answer is a Dockerfile change and a
   rebuild, not run-time privilege.
3. **Never widen the mount surface.** `ai-box` mounts one project directory, the
   per-image state directory, and optionally one key file. Do not add `~/.ssh`,
   `~/.gitconfig`, `~/.aws`, `/var/run/docker.sock`, or any parent-of-many-projects path.
   The guard stays, and it refuses in both directions: the tree paths (`$HOME`, `/`,
   `/home`, `/root`, `/etc`, `/usr`, `/var`, `/opt`, `/boot`, `/proc`, `/sys`, `/dev`,
   `/srv`, `/mnt`, `/media`) and the credential-bearing ones (`~/.aikeys`, the state
   directory, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`, `~/.config`,
   `~/.local`). A directory the README calls unreachable must not be mountable by hand.
4. **Never remove `--cap-drop=ALL`, `--security-opt no-new-privileges`, or the non-root
   `--user`** from the default run path. `-d` (debug) is the one sanctioned relaxation
   and it must stay opt-in.
5. **Version bump on every release**, and never stamp a version into prose by hand.
   `scripts/stamp-version.sh` rewrites every `ai-box-v<version>` in the documentation to
   the current one. If a line must name a specific older release, put `stamp:keep` in a
   comment on that line. The changelog is never stamped: its version references are
   history and are correct as written.
   `scripts/stamp-version.sh` owns the places where the current version appears, and
   `pack.sh` refuses to build an archive when they drift. Releases up to 2.0.3 shipped a
   README claiming 1.6.2 because each edit search-and-replaced the *assumed* previous
   value, and a replacement whose search string is wrong silently does nothing. Any change to a Dockerfile, script, or shipped
   default requires an increment in `VERSION` and an entry in `CHANGELOG.md`.
6. **Archive naming.** Releases are `ai-box-v<VERSION>.tar.gz` containing a
   single top-level directory `ai-box-v<VERSION>/`. Two different releases
   extracted into the same parent must never collide. `scripts/pack.sh` enforces both;
   do not add a `--force` flag that lets it overwrite an existing archive.
7. **Never overwrite an existing deliverable.** New file, new version suffix.
8. **Never bind-mount a single file for anything the container writes.** A single-file
   mount pins an inode: `rename()` over it fails, so atomic writes break and interrupted
   in-place writes leave truncated files. Mount the containing directory instead, and
   relocate the app's file into it (`CLAUDE_CONFIG_DIR`) if needed. Read-only secrets are
   the sole exception, since nothing in the container writes them.
9. **Package lists are split required vs. optional.** Compilers, build tools and
   anything the sanity check exercises are required and must fail the build when
   missing. Convenience libraries (boost, fmt, catch2, gtest, benchmark, perf, ripgrep,
   fd) go in the optional group, installed with `--skip-unavailable` on dnf or one at a
   time on apt, because distros rename and retire leaf packages between releases and one
   dead name must not break the whole image. Never move a compiler into the optional
   group to make a build pass. The Dockerfiles end their install phase with a check
   that compiles a C++23 translation unit with each compiler.
10. **Newest obtainable compilers per image; contract parity, not version parity.**
   Each image ships the newest compilers it can *obtain*, which is not the same as the
   newest its distribution packages: on Ubuntu that means `gcc-16` rather than the default
   `gcc-15`, and Clang from apt.llvm.org rather than the archive's older major. Sources
   that count: the distro's repositories, well-known first-party upstream repositories for
   the compiler itself, and RHEL Software Collections — each with a signature the build
   verifies. `--toolchain distro` is the opt-out for stricter supply-chain policies.
   Never hold one image back so the three match; record the difference with
   `scripts/capabilities.sh`. See D3a.

   The contract *is* identical across images and is enforced by
   `scripts/check-image-parity.sh`: Same
   entrypoint, same user, same paths, same environment variable names, same wrapper
   behaviour — enforced by `scripts/check-image-parity.sh`. Each image otherwise carries
   the newest toolchain its distribution offers, and the three are expected to differ.
   Never hold one image back to match another; record the difference instead
   (`scripts/capabilities.sh`). Enforced by
   `scripts/check-image-parity.sh`, which is the only reason this rule is more than a
   wish. When adding an image, scaffold it from an existing Dockerfile and then run that
   check before anything else: 2.0.0 shipped a Rocky image whose scaffolding had silently
   dropped the Python environment and the sanity check. Same entrypoint, same user, same env
   var names, same paths (`/workspace`, `/opt/venv`, `/opt/toolchains`), same cache layout. A change to one
   image's contract requires the same change to the other.
11. **Credential kind must match the variable.** `api` → `ANTHROPIC_API_KEY`, `oauth` →
   `CLAUDE_CODE_OAUTH_TOKEN`, `bearer` → `ANTHROPIC_AUTH_TOKEN`. Claude Code's precedence
   is cloud provider, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `apiKeyHelper`,
   `CLAUDE_CODE_OAUTH_TOKEN`, then the stored login - so exporting the wrong variable
   silently outranks the right credential. Do not "simplify" this by always exporting
   `ANTHROPIC_API_KEY`.
12. **OS updates are on by default.** `--no-updates` is the opt-out, and it exists for
   reproducibility, not speed. If you touch the update layer, keep `UPDATE_STAMP`
   cache-busting intact: without it the upgrade runs once and is cached forever, and the
   default silently stops doing anything.
13. **One parser for a key profile.** `shared/keyfile-lib.sh` is the only place that
   decides what a line in a `.key` file means, and it is sourced by `lib-common.sh` on
   the host and COPYed into every image for the entrypoint. Never re-implement the
   parsing in a script or in a Dockerfile: three copies of it once disagreed about a
   `kind:` line with no space and about a secret containing `=`, and both showed up only
   as an unexplained 401 inside the container.
14. **The isolation checks assert against the real command.**
   `scripts/verify-isolation.sh` reads `ai-box -n` and checks that argv. Never let it
   re-declare the hardening flags itself: a checker that builds its own copy of the
   command passes happily while the wrapper regresses.
15. **One container engine name, in one place.** `ENGINE` in `lib-common.sh` is the only
   place a script names `docker` or `podman`. Podman is supported, which means podman is
   also tested: `--userns=keep-id` is not optional under rootless podman, because without
   it every file the agent writes into `/workspace` is owned by a subuid and no other check
   notices. SELinux mount options are applied only when the host actually enforces
   SELinux, never unconditionally.
16. **Claude Code stays pinned by the image tag.** Do not enable the auto-updater in the
   default path or install the agent outside the signed apt/dnf repositories. The GPG
   fingerprint check (`31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`) must remain in both
   Dockerfiles and must remain fatal on mismatch.
17. **The Python environment is a venv the user owns, and its `chown` is fatal.** Both
   distros enforce PEP 668. The answer is `/opt/venv`, first on `PATH` and owned by the
   unprivileged user, never `--break-system-packages` and never a run-time install baked
   into an image. If the `chown` of `/opt/venv` is ever made non-fatal, in-session
   `pip install` starts failing with a permission error and the whole feature is silently
   gone.
18. **No third-party GitHub Action in the pipeline that builds this package.** Only
   first-party actions (`actions/checkout`, `actions/upload-artifact`) and `gh`. A
   supply-chain link in the build of a security boundary needs a better reason than
   convenience. Container images used by CI (hadolint) are pinned by tag.

19. **Caches live in the workspace, never in a mount of their own.** `~/.cache` is a
   symlink into `/workspace`, and `XDG_CACHE_HOME` and `CCACHE_DIR` point there too;
   both the symlink and the variables are set, because they catch different
   misbehaviour. The default run path has exactly **two** bind mounts, the project
   directory and the Claude Code state directory. Adding a third for a cache undoes
   this. The corollaries, each of which has a comment in the code saying so:
   - no `VOLUME` may be declared at a path that resolves through the symlink; it
     creates an anonymous volume that shadows the real target;
   - `entrypoint.sh` must create the targets, because `mkdir -p` through a dangling
     symlink fails with "File exists";
   - an unwritable or absent workspace must fall back to the tmpfs, never fail;
   - a probe container that runs with `--entrypoint bash` bypasses all of the above
     and has to set the cache variables itself.
   `$STATE/claude` is **not** a cache. It holds `.credentials.json` and stays where it
   is; a credential must never land in an agent-writable, git-adjacent directory.
20. **Anything the image ships must be verified as the unprivileged user, not as root.**
   Every `RUN` is root, and root bypasses directory permission checks, so a build-time
   check can pass on a path the real user cannot reach. Concretely: `COPY --chmod=MODE`
   applies MODE to any parent directory BuildKit has to create (moby/buildkit#5943), so
   a 0644 file mode yields a 0644 directory with no execute bit. Create destination
   directories with an explicit `install -d -m 0755` before copying into them, and keep
   the post-`USER` verification block at the end of every Dockerfile.

## Shell style

- `#!/usr/bin/env bash` and `set -euo pipefail` in every executable script.
- **No bare `[[ … ]] && cmd` as a statement.** Under `set -e` a false test aborts the
  script. Use `if … then … fi`. This has already bitten this codebase once.
- **Never `die()` from a function that runs inside `$(...)`.** Command substitution runs
  in a subshell, so `exit` kills only the subshell and the caller continues as if nothing
  happened. Validation that must abort belongs in the parent shell: compare
  `assert_profile_file_sane` with `resolve_key_profile`. This has also bitten once.
- **Never name a shell function after a command the project runs.** `doctor.sh` uses
  `ok`/`bad`/`note` rather than `pass`/`fail`, because `pass` is the password manager
  behind `-a pass`.
- Quote every expansion. Use arrays for command construction, never a string of flags.
- User-facing output goes through `log` / `warn` / `die` from `lib-common.sh`, to stderr.
- Prefer `readlink -f "$0"` for locating the package root so symlinked entry points work.
- Every script must pass `bash -n`, and `shellcheck` if it is available.

## Dockerfile style

- `# syntax=docker/dockerfile:1.7`, BuildKit assumed.
- One `RUN` per logical concern; clean the package cache in the same layer that fills it.
- `--no-install-recommends` (apt) / `--setopt=install_weak_deps=False --nodocs` (dnf).
- Every tunable is an `ARG` with a default: `UID`, `GID`, `USERNAME`, `LLVM_VERSION`,
  `CLAUDE_CHANNEL`, `CLAUDE_VERSION`, `PACKAGE_VERSION`.
- Order layers cheap-to-expensive and stable-to-volatile: base packages, then toolchain,
  then Claude Code, then user setup, then `COPY shared/`.
- New tooling goes in the image, never installed at run time.

## Documentation style

- Prose over bullet soup; tables where the content is genuinely tabular.
- Every command shown must be copy-pasteable and must actually work from the package root.
- When a change alters observable behaviour, update `README.md` **and** the relevant
  `docs/*.md` in the same change. Documentation drift is a defect.
- No em-dashes in prose (house style). No emoji.

## Commands

```bash
scripts/build.sh all              # build all three images, with current OS updates
scripts/build.sh --no-updates -t 26.04.1 all   # reproducible build
scripts/build.sh -c 2.1.238 ubuntu
ai-keys add default           # store a credential, no browser
scripts/check-updates.sh          # read-only: installed vs. channel candidate
scripts/upgrade.sh                # rebuild with rollback tags
for i in ubuntu fedora rocky; do scripts/verify-isolation.sh $i; scripts/smoke-test.sh $i; done
scripts/smoke-test.sh ubuntu      # agent + compilers + python venv + examples/
scripts/doctor.sh                 # host-side setup; --fix repairs mechanical problems
scripts/check-file-inventory.sh   # README file table matches the tree
scripts/pack.sh                   # emit ai-box-v<VERSION>.tar.gz
scripts/pack.sh --stage /tmp/out  # same, from a git checkout
AI_BOX_ENGINE=podman scripts/build.sh all   # same everything, under podman
```

## Where the work can happen

This package intends agents to run inside `ai-box`, on a checkout mounted at
`/workspace`. A session there can close the script layer and **cannot** close the image
layer: there is no container engine inside the box, by design, and there never will be.

| Reachable inside the box | Requires a host session |
|---|---|
| `bash -n`, `shellcheck` (in the images since 2.2.0) | `build.sh`, cold-cache builds, `hadolint` |
| `tests/run.sh` | `verify-isolation.sh`, `smoke-test.sh` |
| `check-image-parity.sh`, `check-doc-links.sh`, `check-file-inventory.sh`, `stamp-version.sh` | `capabilities.sh`, `check-updates.sh`, `upgrade.sh`, `doctor.sh` |
| editing, documentation, the credential grep | `pack.sh`, podman paths, anything reading image labels |

**Write the handoff down when you stop.** Five releases of image drift accumulated because
each session finished the script layer, every gate went green, and nobody said out loud
that the image half was still owed. The source-side checks cannot see an unrebuilt image;
only `smoke-test.sh` can, and only on a host.

## Definition of done

Before reporting a change complete, all of these must hold:

1. `bash -n` passes on every file in `scripts/` and `shared/*.sh`.
2. `shellcheck -x -S warning scripts/* shared/*.sh` is clean, or every suppression is
   justified with a `# shellcheck disable=` comment and a stated reason. CI gates on this
   exact command, so a warning is a failed build, not a style note.
3. `scripts/check-image-parity.sh` passes. Hard rule 10 (behaviourally equivalent
   images) is enforced by that script, not by reading; it also catches a Dockerfile that
   interpolates a variable it never declares, which is a failure that otherwise surfaces
   only minutes into a build.
4. All images build from a **cold cache**: `scripts/build.sh -n all`. `hadolint` is clean
   against `.hadolint.yaml`, where every ignored rule carries its justification.
5. `scripts/verify-isolation.sh` and `scripts/smoke-test.sh` pass for ubuntu, fedora and rocky
6. `tests/run.sh` passes, and `scripts/doctor.sh`
   reports no problems on a clean setup.
5. `scripts/smoke-test.sh ubuntu` and `... fedora` both pass. That covers
   `claude --version`, `/etc/toolchain-versions`, a C++23 compile-and-run with every
   compiler in the image, the `/opt/venv` Python tools (resolvable, runnable, writable
   without root, `pytest` actually running a test), and the `examples/` reflection
   programs on any compiler that defines `__cpp_impl_reflection`. Never make a reflection
   check unconditional: it is GCC-only today, and the Ubuntu image must not start failing
   over it.
6. `VERSION` bumped, `CHANGELOG.md` updated, docs updated. `VERSION`, the `CHANGELOG.md`
   heading, the `**Version:**` line in `README.md` and the release tag must agree; CI
   fails the build and the release workflow refuses to publish when they do not.
7. `scripts/pack.sh` produces an archive whose only top-level entry is
   `ai-box-v<VERSION>/` - verify with `tar tzf … | cut -d/ -f1 | sort -u`.
   `pack.sh` asserts this itself and deletes the archive if violated; CI asserts it again
   independently, and also that `.github/` did not leak into it.
8. No credential-shaped string is committed. CI greps for one, so a realistic-looking
   placeholder in documentation will fail the build - write `sk-ant-api03-<the key>`
   rather than twenty plausible characters.
9. If the change touched anything a podman host does differently (mounts, user, engine
   invocation), it was checked with `AI_BOX_ENGINE=podman` too, at least as far as
   `ai-box -n` and `verify-isolation.sh`.
10. `scripts/check-doc-links.sh` passes: renaming a document means updating every
   reference to it, including the ones in scripts and in strings printed at runtime, not
   only the ones in markdown.
11. `scripts/check-file-inventory.sh --strict` passes. Every file added, removed or
   renamed in this change has had its row in the `README.md` inventory added, removed or
   renamed to match, in this same change. CI gates on it.

## Things to ask about rather than decide alone

- Changing the base image (`ubuntu:26.04`, `fedora:44`) or the default compiler.
- **Adding a Dockerfile for a third distribution.** Hard rule 10 says the images stay
  behaviourally equivalent, and every image added is another one that has to be built,
  isolation-checked, smoke-tested and kept equivalent on every release. Two is a
  deliberate number: one LTS and one fast-moving. See the note in `CHANGELOG.md`
  and `CHANGELOG.md` 1.6.0 for the reasoning, which is about maintenance cost rather than
  difficulty.
- Adding a new bind mount or a new capability to the default run path.
- Adding a network-facing component (proxy sidecar, MCP server, exposed port).
- Anything that makes the isolation weaker in exchange for convenience.

## Known constraints of the environment

- The Ubuntu image takes every compiler from the Ubuntu archive (GCC 15/16, Clang 21 on
  26.04), so a normal build has no third-party compiler repository. Only the opt-in
  `LLVM_FROM_UPSTREAM=1` path touches `apt.llvm.org`, and that path fails at `llvm.sh`
  when upstream has no packages for the codename yet. Prefer the archive.
- `gcc-16` on 26.04 is a snapshot branch, not a released GCC 16.1. It is installed but is
  not the default; changing `GCC_DEFAULT` is a decision to discuss, not a silent edit.
- `docker build` needs several GB of free space per image; LLVM dominates.
- `claude --version` is the authoritative in-image version; the npm dist-tag consulted by
  `check-updates.sh` is a reference point only, and the apt candidate may carry a
  packaging suffix (`2.1.238-1`) that the dnf one does not.
