# Contributing to ai-box

Thank you for your interest in ai-box.

ai-box is an AI development box: a container with a real C++ and Python toolchain, in which
an AI coding agent can work on your project while staying isolated from the rest of your
machine. The agent can be Claude Code, Codex, Gemini CLI, Grok, or several of them, chosen
when the image is built. Inside the box there is no `sudo`, no way to become root, no
access to your SSH keys or cloud credentials, and no container engine socket. The agent
sees one project directory and nothing else, which is what makes it reasonable to let it
run commands without approving each one.

If you have not used it yet, **start with [`README.md`](README.md)** — what it does, how to
build or pull the images, and how credentials work. This file is about contributing to the
package itself.

Contributions are welcome, and so are bug reports, questions, and "this documentation
confused me". The last of those is genuinely useful: much of this package exists because
somebody was confused by a container in a way that cost them an afternoon.

## Good first contributions

- **Documentation that misled you.** If a command in the README does not do what it says,
  that is a bug worth reporting even if you worked around it.
- **A distribution package that did not resolve.** Package names move between releases; the
  optional lists exist to absorb that, and a note about what was missing on your system
  helps.
- **A vendor CLI that changed.** The agent CLIs move fast. If an install method or an
  environment variable has changed, saying so is a real contribution.
- **Test cases**, especially for the mount guard: every case in
  `tests/mount-guard.test.sh` came from someone noticing a directory that should have been
  refused and was not.

## The one thing to know before proposing a change

ai-box is a **security boundary first** and a convenience second. When the two conflict,
the boundary wins and the inconvenience gets documented.

In practice a patch that widens what the container can reach — a new mount, a new
capability, a network path — will be asked for a justification most projects would not ask
for. That is not obstruction and not a judgement about the patch. The value of the package
is that the list of things it exposes is short and defensible, so growing that list is the
one kind of change that needs an argument as well as code.

Everything else — a tool in an image, a better error message, a fix, a document — is just a
normal contribution.

## Before you open a pull request

The full rules, style and definition of done are in [`AGENTS.md`](AGENTS.md), which applies
to human and AI contributors alike. The short version:

```bash
scripts/ci-local.sh
```

That runs exactly what CI runs, from the same definition: the workflow calls the same
script. Run it as an ordinary user, never with `sudo` — CI runs unprivileged, and running
as root hides failures. A test that creates a directory under `/home` passes as root and
fails on a runner, which is how one shipped broken.

If you changed a Dockerfile, or a script that runs inside a container, add the image half:

```bash
scripts/ci-local.sh --with-images     # about 35 minutes
```

That second block matters more than it looks. Everything in the first block checks the
*source*; only the second sees the *image*. This package once shipped five releases whose
images told users to read a document that had been deleted, with every source check passing
the whole time.

CI runs the same commands. Image builds run on `main`, weekly, and on pull requests
labelled `build-images`, so a documentation change stays fast.

## The checks are not bureaucracy

Every self-check exists because something shipped broken:

| Check | The defect that caused it |
|---|---|
| `check-image-parity.sh` | an image shipped with no Python environment, and a reference to a variable it never declared |
| `check-doc-links.sh` | six references to a renamed document, two printed to users at runtime |
| `check-file-inventory.sh` | files added to the package and never documented |
| `stamp-version.sh --check` | eight consecutive releases claiming the wrong version |
| `pack.sh` allowlist | a release that shipped without one of its three images |
| `tests/mount-guard.test.sh` | `/etc` was refused while `/etc/ssh` was not |

Please do not work around one. If a check is wrong, fix the check in the same pull request
and say so; that is a good contribution too.

## Two things this codebase learned the hard way

Both cost a release, and both are easy to repeat:

- **A bare `[[ … ]] && cmd` as a statement** aborts the script under `set -e` when the test
  is false. Use `if … then … fi`.
- **`die()` called from a function running inside `$(...)`** kills only the subshell; the
  caller carries on as though nothing happened. Validation that must abort belongs in the
  parent shell.

And one that is not a shell rule: **an edit that reports success is not evidence that
anything changed.** A search-and-replace against an assumed string silently does nothing
when the assumption is wrong. That has caused five separate defects here. Check the result,
not the exit status.

## Commits and versions

- Explain *why* in the commit message; the what is in the diff.
- Any change to a Dockerfile, a script or a shipped default needs a `VERSION` bump and a
  `CHANGELOG.md` entry.
- Semantic versioning as described at the top of `CHANGELOG.md`: MAJOR breaks a workflow,
  MINOR adds capability, PATCH fixes.

## Reporting a security issue

Not as a public issue. Use the Security tab's private reporting, and read
[`SECURITY.md`](SECURITY.md) first: it states plainly what the sandbox does and does not
claim, and several things that look like weaknesses are documented, deliberate limits.

## Scope

Some things are deliberately out of scope, with the reasoning in
[`docs/design-decisions.md`](docs/design-decisions.md): a fourth distribution, MCP servers
by default, an egress filter inside the agent's own container, a Node toolchain for project
work, and auto-installing dependencies from a project manifest at container start.

Proposing one of these is welcome if you think the reasoning no longer holds — say which
part changed. That is a discussion worth having.
