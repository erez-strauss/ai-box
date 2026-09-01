# ai-box project roadmap

**Written against:** v2.0.11 · 47 files, ~9,700 lines, of which ~2,900 are documentation
**Companions:** `docs/design-decisions.md` (settled decisions, open work),
`CHANGELOG.md` (history)

This is a proposal, not a plan of record. Items marked **ask** change a default or widen
the surface and need a decision before implementation.

---

## 1. Where the project actually stands

A whole-tree read gives a clear picture, and it is not entirely flattering.

**Proportions.** 3 Dockerfiles (1,218 lines), 18 scripts (2,700), 5 documents (1,959),
4 test files (137), 2 examples (330), a 1,283-line changelog. Documentation and scripts
each outweigh the thing being documented, which is defensible for a security tool but
means drift is the dominant risk — and drift has in fact been the dominant defect class.

**The gates work, and they were earned.** Nine self-checks now run before a release, and
almost every one exists because something shipped broken: parity (a Rocky image with no
Python), doc links (six references to a renamed file), version stamps (eight releases
claiming 1.6.2), inventory, pack allowlist (a whole image directory missing from a
tarball). This is the project's most valuable and least visible asset.

**The weakest area is test coverage of the thing that matters.** 137 lines of unit tests
cover the key parser and the shared library. There is nothing that tests `ai-box`'s
argument handling, `build.sh`'s flag resolution, or the entrypoint's cache logic, and each
has produced a real defect. The images themselves are only tested by being built.

**The second weakest is that nothing shows a person how to work in the box.** The former
`examples/` directory held compiler probes for the smoke test, which the smoke test now
generates itself. `docs/project-template.md` covers the four things agents get wrong;
worked example projects are still missing.

---

## 2. How this compares to similar projects

The README carries a feature comparison; this is the strategic version — where each
project is genuinely ahead, and what this one should take from it. Every link below was
checked and resolves; a few sit behind bot protection and may need a browser rather than
`curl`.

| Project | Its strength | What ai-box should learn |
|---|---|---|
| [Anthropic dev container](https://github.com/anthropics/claude-code/tree/main/.devcontainer) | default-deny egress via iptables/ipset, vendor-maintained | the egress story. It grants `NET_ADMIN`+`NET_RAW` to do it; ai-box refuses and therefore has no default network policy at all. The largest honest gap. |
| [RchGrav/claudebox](https://github.com/RchGrav/claudebox) | 15+ language profiles, per-project firewall allowlists | breadth, and per-project policy. ai-box is deliberately C++/Python; profiles are a plausible extension of `--python-tools` and `--agents`. |
| [dagger/container-use](https://github.com/dagger/container-use) | per-agent isolated environments with git branches, MCP-native | the MCP model. This is the closest existing thing to the two-service design in §5, and worth reading before writing any of it. |
| [boxlite-ai/claudebox](https://github.com/boxlite-ai/claudebox) · [microsandbox](https://github.com/microsandbox/microsandbox) | microVM isolation, a real kernel boundary | the honest ceiling of what a container can claim. Name as the upgrade path in `SECURITY.md`; do not chase. |
| [Dev Containers spec](https://github.com/devcontainers/spec) · [containers.dev](https://containers.dev/) | an ecosystem: `features`, IDE support, one committed config | these images already work as devcontainers by accident (see `docs/ide-clion.md` §8). Making that supported is cheap and buys IDE integration free. |
| [distrobox](https://github.com/89luca89/distrobox) · [toolbx](https://github.com/containers/toolbox) | seamless host integration across many distros | nothing. Their goal is the opposite of ours: they deliberately dissolve the boundary. Useful as a contrast in `SECURITY.md`. |
| [Nix](https://github.com/NixOS/nix) | genuine reproducibility, content-addressed | `--no-updates` plus `--os-tag` plus a pinned agent is a weak approximation. Digest-pinning every base image closes most of the gap cheaply. |
| [Gitpod](https://github.com/gitpod-io/gitpod) · [Codespaces](https://github.com/features/codespaces) | ephemeral, prebuilt, remote | prebuilds. A 40-minute cold build is a wall in front of every new user. |
| [awesome-AI-sandbox](https://github.com/webcoyote/awesome-AI-sandbox) | a survey of the whole field | where to check before building something that exists. |

**The one thing ai-box does better than all of them:** the credential model. A read-only
file mount, one parser shared by host and container, kind-to-variable mapping, refusal to
accept a key inside the project, and a store that never enters an image layer. Most
alternatives pass `ANTHROPIC_API_KEY` as an environment variable and stop there.

**The one thing it does worst:** egress. Unrestricted by default, with a documented
sidecar nobody will build. Every reviewer will call this first.

## 3. Proposed next steps

### 3.1 Publish images (2.1.0) — the highest-leverage item

Nothing else changes adoption as much. A 40-minute cold build is a wall in front of every
new user, and it also means almost nobody will ever verify the build reproduces.

- Publish `ghcr.io/<owner>/ai-{ubuntu,fedora,rocky}` from the existing CI matrix.
- Sign with [cosign](https://github.com/sigstore/cosign), publish an SBOM with [syft](https://github.com/anchore/syft), attach both to the release. **ask**: this
  adds a trust root, which hard rule 18 exists to limit.
- `ai-box --pull` to fetch rather than build; keep local build as the default so the
  supply chain stays inspectable.
- Digest-pin the base images in the published variant, which also closes most of the
  reproducibility gap against Nix.

### 3.2 Egress policy that people will actually use (2.2.0, **ask**)

The current answer is a documented tinyproxy sidecar. Nobody builds it.

Proposal: `ai-box --egress strict|open` with a maintained allowlist covering the agent
endpoints plus common registries, implemented as a proxy container that ai-box starts and
tears down, with `HTTPS_PROXY` injected. Not iptables inside the agent container, because
that needs `NET_ADMIN` and this project has refused that on purpose.

Honest caveat: an HTTP proxy allowlist is weak against a determined agent, and should be
described as a mistake-catcher rather than a containment boundary.

### 3.3 Fill the testing gap (2.1.x)

- Unit tests for `ai-box` argument handling via `--dry-run`, `build.sh` flag resolution,
  and `safe_hostname`/`state_dir` edge cases. All are pure shell and cheap.
- A container-level test that runs the entrypoint against a workspace and asserts the
  cache layout — the logic that has produced three separate defects.
- `shellcheck` at `-S style`, not just `-S warning`.

### 3.4 The project-facing documentation gap (2.1.0)

Already open work item 2, restated because it is the most user-visible: a project
`CLAUDE.md` template and two worked example projects (`cpp-cmake`, `python-uv`), with
a new `examples/` holding projects rather than compiler probes.

Agents in the box reliably try to `sudo`, install packages, write into `/opt/venv`, and
build in the source tree. A template that says where things go prevents all four.

---

## 4. More tools in the images

v2.0.11 adds the C++ verification set as optional packages: **[cppcheck](https://github.com/danmar/cppcheck)**, **[lcov](https://github.com/linux-test-project/lcov)**,
**[gcovr](https://github.com/gcovr/gcovr)** (also via pip, so coverage works even where the distro lacks it),
**[include-what-you-use](https://github.com/include-what-you-use/include-what-you-use)**, **elfutils**, **nlohmann-json**, **eigen3**, **doxygen** with
**graphviz**, **binutils**, **patchelf**. `clang-tidy` and `clang-format` were already
present via the Clang packages.

Worth considering next, in rough order of value:

| Tool | Why | Caution |
|---|---|---|
| [`pre-commit`](https://github.com/pre-commit/pre-commit) | agents should run the project's own hooks | pip leaf, cheap |
| [`bear`](https://github.com/rizsotto/Bear) | `compile_commands.json` for non-CMake builds | small |
| [`conan`](https://github.com/conan-io/conan) | versioned C++ dependencies without vendoring | pip install into `/opt/venv`; verify it honours `XDG_CACHE_HOME` before adding, do not add a mount |
| [`hyperfine`](https://github.com/sharkdp/hyperfine) | benchmarking that is not `perf` | not in all repos |
| `strace`/`ltrace` | already present; document them | none |
| [`rr`](https://github.com/rr-debugger/rr) | record-replay debugging, transformative for C++ | needs `perf_event_paranoid` on the host; probably cannot work in the container |
| `valgrind --tool=helgrind` | present, undocumented | none |

**Not** recommended: a full scientific stack beyond numpy/pandas; a Node toolchain for
project work; Java/Go/Rust profiles (that is claudebox's job, and doing it badly is worse
than not doing it).

---

## 5. AI tooling, and the two MCP services

### 5.1 The decomposition

There are two distinct services, and separating them makes the security argument tractable
in a way that a single "ai-box MCP" does not.

1. **Package service** — manage images and instances: query capabilities, check for
   updates, build an image, start an instance.
2. **Instance service** — run commands inside an instance that already exists.

The instinct to sort tools into "read-only" and "mutating" is the wrong cut. The invariant
that matters is **who chooses the mount surface**, because that is what every guarantee in
`SECURITY.md` rests on.

| Tool | Chooses the mount surface? | Verdict |
|---|---|---|
| `list_images`, `image_capabilities`, `check_updates`, `list_instances` | no | safe; ship first |
| `exec_in_instance` (service 2) | no — inherits a surface fixed at creation | safe, and the highest-value tool here |
| `build_image` | **yes**, through the build context | constrain hard |
| `start_instance` | **yes**, the project directory is a parameter | the dangerous one |

By that test the instance service is the *safest* component in the design, not the most
dangerous. An instance started by a human through `ai-box` already had its mounts,
capabilities and credential fixed; a tool that runs commands inside it cannot change any
of them. Routing an agent's commands there is strictly better than running them on the
host, which is what happens today.

### 5.2 The two dangerous tools, and how to constrain them

**`start_instance` must never accept a path.** If `project_dir` is a free parameter, an
agent asks for `/` and the whole boundary is gone — the guard in `ai-box` protects a
human's command line, not an MCP call. It should accept a **name** from a registry the
human populated (`ai-box register ~/src/foo`), and resolve it. Same shape as `.ai-profile`
naming a key profile rather than carrying a key.

**`build_image` is subtler than it looks.** A build context is a host path, and BuildKit
can `COPY` anything out of it into an image you then run. A free-form context parameter is
therefore an arbitrary host-file read wearing the costume of a build verb. Restrict it to
the package's own three Dockerfiles with validated build args, or leave it out:
`scripts/build.sh` is a fine human-run command and building rarely needs to be agentic.

### 5.3 The reachability rule, which decides everything else

Both services must run **on the host**, because they talk to the container engine. So they
hold host authority and are a textbook confused deputy: any agent that can call them
inherits it.

**An agent inside a box must not be able to reach them.** If it can, it requests a new
instance mounting `/` and the containment is theatre. This is not hypothetical — an agent
in a box has network access and sits on a bridge that can usually route to the host. So:
bind to a unix socket in the host user's runtime directory, or to loopback on a network
the boxes cannot route to, and have `ai-box` assert that separation.

The worked example makes it concrete. Suppose **Gemini runs on the host** and **Grok runs
inside a box**: Gemini holds the authority and decides what Grok gets to see; Grok has a
shell and no say. The MCP services exist for Gemini. Grok must not be able to call them,
and already has a shell so gains nothing if it could.

Two details that fall out of that topology and are worth keeping deliberately:

- **Different credentials, different blast radii.** Gemini uses `GEMINI_API_KEY` on the
  host; Grok uses `GROK_CODE_XAI_API_KEY` mounted read-only in the box. `ai-keys` already
  models this. Gemini's key should never be mounted into a box.
- **`exec` bypasses the entrypoint**, so commands the host agent sends into a box do *not*
  inherit the credential the entrypoint exported into PID 1. The host agent can therefore
  drive builds and tests inside the box without touching the box agent's key. That is an
  accident of the design worth preserving on purpose, and a test should pin it.

### 5.4 Consequences to decide before building

- **Concurrent writers.** Two agents writing `/workspace` with no locking is a race:
  the in-box agent editing while the host agent's `exec` runs a build. Decide whether the
  host agent's role is *drive the box* (safe) or *collaborate in it* (needs a convention,
  probably a lock file or separate build directories).
- **Audit.** Every call should log the instance, the command and the project it was
  mounted on. That log is the only record of what an agent actually did, and it is the
  main thing this design offers over letting an agent run commands directly.
- **Prior art.** [dagger/container-use](https://github.com/dagger/container-use) already
  implements something close to service 2. Read it before writing.

### 5.5 Implementation order

1. `exec_in_instance` plus the read-only queries. Real value, no new authority, and it
   turns "run this untrusted thing safely" into one tool call for any host-side agent.
2. `start_instance` from a registry, with the path parameter structurally impossible.
3. `build_image` restricted to the package's own Dockerfiles, or not at all.

Ship as a separate optional component, `ai-box-mcp`, with its own README section stating
the reachability rule as a requirement rather than a recommendation.
Specification: [modelcontextprotocol](https://github.com/modelcontextprotocol/modelcontextprotocol)
· [modelcontextprotocol.io](https://modelcontextprotocol.io/).

### 5.6 Agent-facing metadata inside the box

Cheaper than MCP and probably higher value per hour spent: a machine-readable
`/etc/ai-box.json` beside `/etc/toolchain-versions`, carrying the image key, compiler
versions, available libraries, cache paths and the workspace path. Agents parse JSON far
more reliably than a table, and it costs one build step.

### 5.7 Which agent for which work on this project

From direct evidence in this project's history:

- **[Claude Code](https://github.com/anthropics/claude-code)** — suits the multi-file
  refactors this package keeps needing. Caveat observed repeatedly: it reports success on
  a search-and-replace that silently matched nothing, which is how the version stamp
  rotted for eight releases. Verify its changes with a gate, not with its summary.
- **Grok** — the whole-package review it produced was accurate, well-evidenced, and found
  three real defects the author had missed, including one where a stated principle was
  contradicted by the code. Good at "read everything and tell me what disagrees".
- **[Codex](https://github.com/openai/codex)** / **[Gemini CLI](https://github.com/google-gemini/gemini-cli)**
  — largely untested here. Codex is the one to try first: a static binary, no runtime.

**Inside or outside the box?** Run the agent **in the box** on a checkout mounted at
`/workspace`; keep image builds **outside**, because building images from inside a
container needs the Docker socket, the one mount this project will never make.

## 6. Sequenced proposal

| Version | Contents | Risk |
|---|---|---|
| 2.1.0 | published images, `--pull`, project template and example projects, `/etc/ai-box.json` | low, mostly additive |
| 2.1.x | test coverage for `ai-box`/`build.sh`/entrypoint, `-S style` | low |
| 2.2.0 | `--egress strict` (**ask**), read-only `ai-box-mcp` (**ask**) | medium: new component, new network path |
| 2.3.0 | [cosign](https://github.com/sigstore/cosign)/SBOM (**ask**), digest-pinned bases, prebuild cache | medium: new trust roots |
| later | language profiles beyond C++/Python (**ask**), `rr` if it can work | high scope |

**Prerequisite for all of it:** the acceptance run that has never happened —
`verify-isolation.sh`, `smoke-test.sh` and `tests/run.sh` against all three built images,
plus one real session. Several items above assume behaviour that has only been reasoned
about.

---

## 7. Questions for a human

1. **Publish images?** It is the biggest adoption lever and the biggest new supply-chain
   commitment. Both are true.
2. **Is an egress allowlist worth a new component**, knowing an HTTP proxy is a
   mistake-catcher rather than containment?
3. **MCP read-only only, or not at all?** The read-only half is genuinely useful; the
   mutating half should never exist.
4. **Does the project want language breadth**, or is "C++ and Python, done properly" the
   identity? claudebox already occupies the broad position.
5. **Rocky without Clang** — fix, or document as a permanent property of that image?

---

## 8. Link check

Every external link in this document resolved when it was written. Three sit behind bot
protection and return 403 to a scripted request while working normally in a browser:
`containers.dev`, `modelcontextprotocol.io`, and `rr-project.org`. Two upstream issues are
cited elsewhere in the package and are worth keeping to hand, because both cost this
project a release:
[nodejs/node#51752](https://github.com/nodejs/node/issues/51752) (Intl.Segmenter segfaults
without ICU data) and
[moby/buildkit#5943](https://github.com/moby/buildkit/issues/5943) (`COPY --chmod` sets the
mode of a directory it creates).
