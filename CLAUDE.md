# CLAUDE.md

The working agreement for this package is **`AGENTS.md`**, which applies to every agent and
to humans alike. This file exists because Claude Code reads this exact filename; keeping
the agreement in one place is what stops the two drifting apart.

**Read `AGENTS.md` before changing anything here.** It carries the hard rules, the shell and
Dockerfile style, the definition of done, and the split between what a session inside the
box can finish and what has to be handed to a host.

For what the package *is* and how to run it, read `README.md`.

## The short version, so nothing depends on you following a link

- This is a **security boundary first** and a convenience second. A change that widens the
  mount surface, adds a capability, or opens a network path needs a justification most
  projects would not ask for.
- **No secrets in images**, ever: not `ENV`, not a build argument, not a file a `COPY`
  could pick up. Credentials arrive at run time as a read-only file mount.
- **No sudo, no capabilities, no privilege escalation path** in any image.
- **One project directory** is mounted, plus the state directory. Never `$HOME`, `~/.ssh`,
  the key store, or the engine socket.
- **Version bump and a `CHANGELOG.md` entry** for any change to a Dockerfile, a script or a
  shipped default.
- **An edit that reports success is not evidence that anything changed**, and **a gate that
  passes is not evidence that the product works**. Both have cost this project releases.
  Verify the result, and build the images before claiming an image-level fix.

## Claude-specific notes

- `CLAUDE_CONFIG_DIR` is set to `/home/dev/.claude` inside the images, which is the one
  state directory `ai-box` mounts. That is why a login survives `--rm`.
- The `claude` command, the `claude-code` package, `CLAUDE_CODE_OAUTH_TOKEN` and this
  filename belong to Anthropic. They are deliberately not renamed anywhere in the package.
