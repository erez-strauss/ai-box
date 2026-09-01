# Using CLion with the ai-box images

**Applies to:** ai-box v2.0.10 · `ai-ubuntu:26.04`, `ai-fedora:44`, `ai-rocky:10`

This describes editing, building, running and debugging a project inside one of these
images from CLion, and it is honest about the one place where CLion's model and this
project's model disagree.

---

## 1. The thing to understand first

**CLion does not use `ai-box`.** When you configure a Docker toolchain, CLion starts and
manages its *own* container from the same image, with its own flags and its own mount
layout. None of the hardening `ai-box` applies — `--cap-drop=ALL`, `no-new-privileges`,
`--pids-limit`, the read-only credential mount, the refusal to mount `$HOME` — is present
unless you add it yourself in **Container Settings**.

That is not a defect in either tool. They are solving different problems:

| | `ai-box` | CLion Docker toolchain |
|---|---|---|
| Purpose | contain an autonomous agent | give the IDE a compiler |
| Runs | untrusted-ish generated commands | commands you asked for |
| Mount | one project, at `/workspace` | the project, at a path CLion picks |
| Credential | mounted read-only, `kind`-aware | none, and none is needed |
| Hardening | applied by default | whatever you configure |

The practical consequence: **do not put credentials into the CLion container.** It has no
use for them, and it is the less contained of the two. Keep `~/.aikeys` out of Container
Settings entirely. If you want an agent, run `ai-box` in a terminal against the same
project directory; the two coexist fine.

---

## 2. Prerequisites

Build the images first. Everything CLion needs — `cmake`, `ninja`, `make`, `gcc`/`g++`,
`gdb` — is already in all three:

```bash
scripts/build.sh all
scripts/capabilities.sh          # what each image actually has
```

CLion 2021.3 or newer for the Docker toolchain; recent versions are better at detecting
compilers inside containers. Docker (or Podman with the Docker-compatible socket) must be
reachable from the IDE, and CLion's Docker connection must be configured under
**Settings | Build, Execution, Deployment | Docker**.

---

## 3. Set up the toolchain

**Settings | Build, Execution, Deployment | Toolchains**, `+` → **Docker**.

1. **Image**: `ai-fedora:44` (or `ai-ubuntu:26.04`, `ai-rocky:10`).
2. Let CLion detect CMake, make, the compilers and the debugger. The images put
   everything on `PATH` through the image's own `ENV`, which CLion inherits, so detection
   normally just works.
3. **Container Settings** — this is where the flags go. See §4.
4. Name the toolchain after the image (`ai-fedora`), because you will want more than one.

Create one toolchain per image you use. They are not interchangeable: the images ship
deliberately different compiler versions (decision D3a), so a CMake cache built against
one is not valid for another.

If detection fails, set the paths explicitly:

| Field | Ubuntu | Fedora | Rocky |
|---|---|---|---|
| CMake | `/usr/bin/cmake` | `/usr/bin/cmake` | `/usr/bin/cmake` |
| Debugger | `/usr/bin/gdb` | `/usr/bin/gdb` | `/usr/bin/gdb` |
| C compiler | `/usr/bin/gcc` | `/usr/bin/gcc` | `/opt/rh/toolset/bin/gcc` |
| C++ compiler | `/usr/bin/g++` | `/usr/bin/g++` | `/opt/rh/toolset/bin/g++` |

Rocky is the one to watch. Its newest compilers come from a Software Collection under
`/opt/rh`, reached through a version-independent `/opt/rh/toolset` symlink that the image
puts on `PATH`. If CLion detects `/usr/bin/gcc` there, it has found RHEL's older *system*
compiler, not the toolset — set the paths by hand. Rocky carries Clang 21 from its base
repositories, one major behind the other two images, so a Clang toolchain is configurable
there as well. `scripts/capabilities.sh` prints the exact versions per image.

**Use the container's `gdb`, not the bundled one.** The binaries are built inside the
container against that image's glibc; the bundled debugger on your host may not match.

---

## 4. Container Settings

Paste into the **Container Settings** field of the toolchain:

```
--cap-add=SYS_PTRACE --security-opt seccomp=unconfined --memory 12g --cpus 8
```

Reasoning for each:

- **`--cap-add=SYS_PTRACE`** is required for debugging. `gdb` attaches with `ptrace`, and
  without this capability breakpoints fail with a permission error that looks like a CLion
  bug and is not.
- **`--security-opt seccomp=unconfined`** is the second half of the same problem. Modern
  Docker's default seccomp profile permits `ptrace`, but `personality`, which `gdb` uses to
  disable address-space randomisation, is often blocked. Symptoms: breakpoints that do not
  bind, or addresses that move between runs. If you would rather keep seccomp on, leave
  this out and add `set disable-randomization off` to a `.gdbinit`.
- **`--memory` / `--cpus`** because a parallel C++ build in an unbounded container will
  happily consume the machine. Match what you give `ai-box`.

If you want the IDE's container hardened closer to `ai-box`, add:

```
--cap-drop=ALL --cap-add=SYS_PTRACE --security-opt no-new-privileges
```

`--cap-drop=ALL` followed by `--cap-add=SYS_PTRACE` is the useful combination: everything
dropped except the one capability the debugger genuinely needs.

**Do not add** `-v ~/.aikeys:...`, `-v ~/.ssh:...`, the Docker socket, or `--privileged`.

---

## 5. The cache trap, and how to avoid it

This is the one place where these images need a setting CLion will not guess.

The images set `CCACHE_DIR=/workspace/.ccache-<image>` and
`XDG_CACHE_HOME=/workspace/.cache-<image>`, and make `~/.cache` a symlink into
`/workspace` (decision D1: caches live in the project). Those directories are created by
the image's **entrypoint**.

CLion mounts your project at a path of its own choosing — commonly under `/tmp` — and does
**not** run the entrypoint. So inside a CLion container:

- `/workspace` is the image's own empty directory, not your project;
- `CCACHE_DIR` and `XDG_CACHE_HOME` point into it;
- anything written there lands in the container's ephemeral layer and is lost;
- `~/.cache` may resolve to a directory that does not exist, which makes `pip` and other
  XDG-aware tools fail with confusing errors.

Nothing is corrupted, but ccache silently does nothing, which shows up as builds that are
never incremental across container restarts.

**The fix**, in **Settings | Build, Execution, Deployment | CMake**, per profile, in
**Environment**:

```
CCACHE_DIR=/tmp/ccache-ide
XDG_CACHE_HOME=/tmp/cache-ide
```

Caches then live in the container's tmpfs: fast, and gone when the container stops. To
keep them between sessions, add a volume in Container Settings instead:

```
-v ai-box-ide-cache:/tmp/cache-ide
```

and point both variables inside it. A named volume rather than a bind mount, so nothing
new from your host is exposed.

**Do not** point CLion's cache at the same `.ccache-<image>` directory `ai-box` uses. Two
container layouts writing one ccache is not corruption, but the cache keys include paths,
so hit rates collapse and you gain nothing.

---

## 6. CMake profiles

**Settings | Build, Execution, Deployment | CMake**, one profile per toolchain:

| Profile | Toolchain | Build directory |
|---|---|---|
| `Debug-fedora` | `ai-fedora` | `build/fedora-debug` |
| `Release-fedora` | `ai-fedora` | `build/fedora-release` |
| `Debug-ubuntu` | `ai-ubuntu` | `build/ubuntu-debug` |

**Never share a build directory between images.** The compilers differ by major version by
design, and a CMake cache carries absolute compiler paths and ABI results. Sharing one
produces link errors that look like source problems.

Because CLion mounts the project, `build/` appears on your host too. Add `build/` to
`.gitignore` along with `.cache-*` and `.ccache-*`.

Useful CMake options for these images:

```
-G Ninja
-DCMAKE_CXX_COMPILER=g++-16          # Ubuntu, to use GCC 16 explicitly
-DCMAKE_CXX_COMPILER=/opt/rh/toolset/bin/g++   # Rocky, to avoid the system GCC
-DCMAKE_CXX_STANDARD=26
```

`ninja` is present in every image and is the better default for large C++ projects.

---

## 7. Running and debugging

Once a profile is selected, **Run** and **Debug** work normally: CLion builds in the
container, runs the binary in the container, and drives the container's `gdb`.

Points specific to these images:

- **Working directory.** Run configurations default to the CMake build directory. If your
  program expects to run from the project root, set **Working directory** to
  `$ProjectFileDir$`, which CLion maps to the container path.
- **Sanitizers.** ASan, UBSan and TSan runtimes are present. ASan may abort at startup on
  recent kernels with an mmap-randomisation error; `--security-opt seccomp=unconfined`
  plus `ASAN_OPTIONS=detect_leaks=1:abort_on_error=1` usually settles it. If not, the
  kernel-side workaround is `sysctl vm.mmap_rnd_bits=28` **on the host**.
- **Valgrind** is installed and CLion's Valgrind Memcheck integration works, but it needs
  `--cap-add=SYS_PTRACE` too.
- **`perf`** is present on Fedora and Rocky but generally will not work in a container
  without `--privileged` or `CAP_PERFMON`, which is not worth adding. Profile on the host.
- **Core dumps** land wherever the kernel's `core_pattern` says, which is a host setting,
  not a container one. A crash inside a container can drop a large core file into your
  project directory.

---

## 8. Alternative: Dev Containers

CLion 2023.1+ supports Dev Containers, which is a reasonable fit if you want the
configuration committed to the repository rather than living in your IDE settings.

`.devcontainer/devcontainer.json`:

```json
{
  "name": "ai-box fedora",
  "image": "ai-fedora:44",
  "workspaceFolder": "/workspace",
  "runArgs": [
    "--cap-drop=ALL",
    "--cap-add=SYS_PTRACE",
    "--security-opt", "seccomp=unconfined",
    "--security-opt", "no-new-privileges"
  ],
  "remoteUser": "dev",
  "containerEnv": {
    "CCACHE_DIR": "/workspace/.ccache-devcontainer",
    "XDG_CACHE_HOME": "/workspace/.cache-devcontainer"
  }
}
```

This one *can* honour `/workspace`, because `workspaceFolder` is yours to set — which
removes the §5 trap. The cache directories are named `-devcontainer` so they do not
collide with the ones `ai-box` maintains for the same image.

Note that the images are not built to the Dev Containers specification: there is no
`features` support and no `docker-in-docker`. They are ordinary images that happen to work
well as one.

---

## 9. What not to do

- **Do not run CLion itself inside the box.** It is a desktop application; the images have
  no X11, no Wayland and no display stack, deliberately.
- **Do not use the Remote/SSH toolchain with these images.** It needs `sshd`, which is
  absent on purpose: an image that listens on a port is a different security proposition,
  and the Docker toolchain does the same job by mounting rather than syncing.
- **Do not mount the key store, `~/.ssh`, or the Docker socket** into the IDE container.
- **Do not point CLion at `/workspace` expecting your project.** In a CLion-managed
  container that path is the image's own empty directory. Use `$ProjectFileDir$`.

---

## 10. Troubleshooting

| Symptom | Cause |
|---|---|
| Breakpoints never bind | `--cap-add=SYS_PTRACE` missing from Container Settings. |
| Breakpoints bind, addresses move each run | seccomp blocking `personality`. Add `--security-opt seccomp=unconfined`, or `set disable-randomization off`. |
| CLion detects GCC 15 on Rocky | That is RHEL's system compiler. The toolset is at `/opt/rh/toolset/bin`; set the compiler paths by hand. |
| Clang on Rocky is a major behind | Expected: Rocky ships Clang 21 while Fedora and Ubuntu carry 22. Run `scripts/capabilities.sh` for the exact versions. |
| Builds never incremental | ccache is writing into the image layer. See §5. |
| `pip` fails with a cache error | `XDG_CACHE_HOME` points at a directory that does not exist because the entrypoint did not run. See §5. |
| Files created in the container owned by another user on the host | The image was built with a different UID. Rebuild: `scripts/build.sh <image>` passes your `id -u`/`id -g`. |
| Link errors after switching toolchains | A CMake cache shared between two images. Use one build directory per profile. |
| CLion cannot connect to Docker | The IDE needs the daemon directly. With rootless Podman, expose the compatible socket and point CLion at it. |

---

## 11. Reasoning, in short

The Docker toolchain is the right integration because it **mounts** rather than
synchronises: one copy of the source, edited on the host, compiled in the container, with
no rsync step to drift. The cost is that CLion owns the container lifecycle, so this
project's isolation guarantees do not extend to it, and the mount layout is CLion's rather
than `/workspace`.

That trade is acceptable for an IDE, where the commands come from you. It would not be
acceptable for an agent, which is why `ai-box` exists separately and why the two should
not be collapsed into one container.

**Resources**

- Docker toolchain, CLion documentation: <https://www.jetbrains.com/help/clion/clion-toolchains-in-docker.html>
- Using Docker with CLion, JetBrains blog: <https://blog.jetbrains.com/clion/2020/01/using-docker-with-clion/>
- Dev Containers in JetBrains IDEs: <https://www.jetbrains.com/help/clion/connect-to-devcontainer.html>
- This package: `docs/operating-guide.md` for the isolation model,
  `docs/design-decisions.md` D1 (caches) and D3a (compiler versions per image).
