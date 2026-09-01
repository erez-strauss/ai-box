# Project template: a `CLAUDE.md` for work inside ai-box

Copy this into a project you open in the box, as `CLAUDE.md` or `AGENTS.md`, and edit the
project-specific parts. It exists because agents in a container reliably try the same four
wrong things, and one short file prevents all of them.

The list below is not speculative. It is what agents actually attempted in this box.

---

```markdown
# Working in this project

This project is edited inside an ai-box container. The rules below are about the
environment, not about style.

## The environment

- The project is at `/workspace`. It is the only host directory mounted, and it is
  writable. Everything you change here is visible on the host immediately.
- You are `dev` (uid 1000), not root, and you cannot become root.
- `$AI_BOX_IMAGE` names the image (`ubuntu`, `fedora`, `rocky`). The compilers differ
  between them by design, so use it in build paths.
- `/etc/toolchain-versions` lists every compiler and tool in this image, with versions.
  Read it instead of guessing what is installed.

## Four things that will not work

1. **`sudo`** is not installed, and would be refused anyway: the container runs with
   `no-new-privileges` and no capabilities. There is no way to become root, by design.
2. **Installing system packages** (`dnf install`, `apt install`) fails for the same
   reason. If a library is genuinely missing, it belongs in the image: say so, and the
   maintainer rebuilds with it. Do not work around it.
3. **`pip install` into the system Python.** `/opt/venv` is the tooling virtualenv and is
   on `PATH`; it is writable, but anything you add there is lost when the container exits.
   For project dependencies, create a project virtualenv (below).
4. **Building in the source tree.** Build out of tree, keyed by image, or two images will
   fight over one set of object files.

## What to do instead

```bash
# Build, out of tree and per image
cmake -S . -B "build/$AI_BOX_IMAGE" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build "build/$AI_BOX_IMAGE" -j"$(nproc)"

# Project Python dependencies, per image because ABIs differ
python -m venv ".venv-$AI_BOX_IMAGE"
source ".venv-$AI_BOX_IMAGE/bin/activate"
pip install -e '.[dev]'
```

Add `build/`, `.venv-*`, `.cache-*` and `.ccache-*` to `.gitignore`. The last two are
created by the box itself: compiler and tool caches live in the project directory, so they
appear here and should never be committed.

## Caches

`~/.cache` is a symlink into `/workspace`, and `CCACHE_DIR` and `XDG_CACHE_HOME` point
there too. That is deliberate: a cache belongs to the project that produced it. It means
the first build after a fresh clone is cold, and that deleting the project deletes its
cache.

## Network

Outbound network is available unless the box was started with `-N none` or behind an
egress proxy. Do not assume you can reach an arbitrary host; if a fetch fails, that may be
policy rather than a bug.

## Things worth saying in your project

<!-- Replace this section. Examples of what belongs here: -->
- Which compiler this project targets, and why (`g++-16` for reflection, `clang++` for a
  sanitiser build, and so on).
- The test command, and how long it takes.
- Anything that must not be run inside the box because it needs host access.
- Where generated files go, so they are not mistaken for sources.
```

---

## Why each item is here

**`sudo`.** The single most common wasted cycle. An agent tries `sudo dnf install`, gets a
confusing error, tries `su`, tries again with a different package manager, and burns several
minutes before concluding the environment is broken. It is not broken; it is doing its job.
Saying so in one line at the top prevents all of it.

**System packages.** The instinct to install a missing library is right in general and
wrong here: the image is the unit of reproducibility, so a package added at run time
disappears and takes the reproducibility with it. Routing that to a rebuild keeps the image
honest.

**`/opt/venv`.** It is on `PATH` and writable, which makes it look like the right place.
It is the *tooling* venv — ruff, mypy, pytest, and a scientific stack. Project
dependencies with a lockfile or an extension module belong in a project venv, keyed by
image because the Python versions differ (3.14 on Ubuntu and Fedora, 3.12 on Rocky).

**Out-of-tree builds.** The images ship deliberately different compiler versions. A CMake
cache records absolute compiler paths and ABI results, so sharing one between images
produces link errors that look like source problems.
