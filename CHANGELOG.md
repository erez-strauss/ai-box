# Changelog

All notable changes to ai-box. Versions follow semantic versioning:
MAJOR for a change that breaks an existing workflow, MINOR for new capability,
PATCH for fixes that change nothing about how you use it.

## 2.3.7 - 2026-08-29

### Fixed

- **The mount guard now judges the path before checking that it exists.** `ai-box` resolved
  the project directory with `cd … && pwd -P` first, so `-p /opt/foo` or `-p /etc/ssh` on a
  machine where those are absent produced `no such directory` rather than
  `refusing to mount … that is a system directory`. The refusal was right; the reason was
  wrong, and a user typing a system path deserves to be told that is why.

  The path is now canonicalised with `readlink -m`, which does not require existence, the
  guard runs, and only then is the directory required to exist. A harmless path that is
  missing still says `no such directory`.

- **`tests/mount-guard.test.sh` no longer depends on what the filesystem contains.** The
  case `beneath a system tree: /opt/foo` failed on a host where `/opt/foo` does not exist
  and an unprivileged user cannot create it: the stricter helper added in 2.3.5 correctly
  reported that the guard had never been reached. With the ordering fixed, the tests create
  nothing at all, `/root` no longer needs skipping, and `/root/.ssh` and `/boot/efi` are
  checked too. 37 assertions, identical as root and as an unprivileged user, with both run.

- **`ci-local.sh` borrows shellcheck from an image when the host lacks it.** Reporting a
  hard failure told a contributor to install a tool that every ai-box image already ships.
  It now runs the check inside the default image when one is built, says so, and only fails
  outright when neither a host binary nor an image is available.

  The comment explaining this could not begin with the tool's name: a comment line starting
  with `shellcheck` is parsed as a directive by shellcheck itself, which failed the very
  check being described.

## 2.3.6 - 2026-08-29

### Added

- **`scripts/ci-local.sh`**, and the CI workflow now calls it instead of repeating the
  commands. This removes a duplication that was already drifting: the checks lived only in
  `.github/workflows/ci.yml`, which is not in the released archive, so "run what CI runs"
  meant transcribing YAML by hand. The `checks` and `package` jobs are now one line each.

      scripts/ci-local.sh                 lint, tests, gates, archive invariants
      scripts/ci-local.sh --with-images   also builds and checks all three images
      scripts/ci-local.sh --pack-to DIR   keep the archive, which is how CI gets its artifact

- **It warns when run as root**, because CI runs unprivileged and root hides real failures.
  That is not hypothetical: a mount-guard case that creates a directory under `/home`
  passed as root and failed on a runner, and it shipped that way. The warning names the
  reason rather than just the fact.

- **It says what it did not do.** Without `--with-images` it ends by pointing at the image
  half, which is the part source checks structurally cannot cover and the part that has
  been skipped often enough to matter.

- When `shellcheck` is missing it says so, fails, and mentions that every ai-box image
  ships it, so `ai-box -- shellcheck …` works without installing anything on the host.

### Changed

- `CONTRIBUTING.md`'s pre-pull-request block is now one command instead of six, with the
  reason for running it unprivileged.
- `AGENTS.md` keeps the numbered definition of done, because it explains why each item
  exists, and now says which script actually runs them and that CI calls the same script so
  the two cannot drift.

## 2.3.5 - 2026-08-29

### Fixed

- **`tests/mount-guard.test.sh` failed on a CI runner**, on the one case that expects a
  directory to be *allowed*. The test created `/home/someone-else-proj` to check that a
  sibling user's home is not refused; an unprivileged runner cannot create a directory
  under `/home`, so `ai-box` refused with `no such directory` and the assertion read that
  as the guard rejecting it. The guard was correct throughout; the test assumed it was
  running as root.

- **And the same assumption was hiding false passes.** The helpers treated *any* non-zero
  exit as a refusal, so every case naming a path the test could not reach passed for the
  wrong reason. `/root` was one: an unprivileged user cannot enter it, so `ai-box` never
  consulted the guard and the case passed regardless of what the guard did.

  Both helpers now match the message. A refusal counts only when `ai-box` says
  `refusing to mount`; `no such directory` is reported as a broken test case rather than a
  pass, and a directory that cannot be created is reported as an environment problem rather
  than a guard failure. `/root` is skipped with a stated reason when it is not readable,
  and the sibling-home case is rooted in the test's own temporary tree, where it can be
  created at any privilege level.

  The suite now passes as root and as an unprivileged user, and both were run.

## 2.3.4 - 2026-08-29

### Fixed

- **`check-file-inventory.sh` has been silently broken since 2.2.0.** The edit that added
  the cache-directory exclusions anchored on a line that exists in `check-doc-links.sh` and
  not in this file, so `NOT_PACKAGE` and `is_not_package()` were never defined while the
  call to them remained. Every run printed `is_not_package: command not found` once per
  file, built an empty file list, compared the README against nothing, and **exited 0**.
  The release gates redirect its output, so it reported success for six releases while
  checking nothing.

  This is the seventh defect in this project from a replacement that reported success and
  changed nothing, and the second where the damage was hidden by a gate's own output being
  discarded. The function is restored, and the check now fails when its enumeration
  produces an empty list: a file list that comes out empty means the machinery broke, not
  that the package is empty.

### Added for repository use

- **`.gitignore` and `.hadolint.yaml` moved into the `.github` bundle.** Both are in
  `pack.sh`'s `NOT_SHIPPED`, so a user extracting the tarball had neither, and anyone
  creating a repository from the tarball alone would have committed their own ccache. The
  `.gitignore` now also covers the agent state directories (`.gemini/`, `.codex/`,
  `.grok/`), project virtualenvs, and the review and workplan notes that are deliberately
  not package content.

## 2.3.3 - 2026-08-29

### Fixed

- **Nine stale version paths in the documentation**, including two lines apart in the
  README telling a reader to extract `ai-box-v2.3.1.tar.gz` and then `cd ai-box-v2.3.2`,
  and an operating guide that still said `ai-box-v1.6.1` eleven releases after 1.6.1.

  The cause was the stamper itself. It matched two exact phrasings, `tar xzf ai-box-v…`
  and `cd ai-box-v…`, so a line reading `tar xzf ~/Downloads/ai-box-v2.3.1.tar.gz` did not
  match while the `cd` two lines below it did, and every path in `docs/` was outside its
  rules entirely. The check passed the whole time, because a rule that matches nothing was
  only reported as drift when its *file* was missing, not when its *pattern* was.

  This is the same failure as the eight releases that claimed version 1.6.2: a list of
  known phrasings pretending to be a general rule. It is now a general rule —
  every `ai-box-v<semver>` in the documentation set is rewritten, wherever it appears and
  however the line is phrased.

### Added

- **`stamp:keep`** as the escape hatch: a line with that marker in a comment keeps the
  version it names, for prose that must refer to a specific older release. Verified by
  pinning a 1.6.1 reference and confirming it survived a stamp that moved everything else.
  `ai-box-vOLD` and `ai-box-vNEW`, used in the side-by-side extraction example, were
  already immune because they are not version numbers.

- The stamped set now covers `README.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`,
  `SECURITY.md` and every file in `docs/`, rather than three files named individually.
  `CHANGELOG.md` is deliberately excluded: its version references are history and are
  correct as written.

## 2.3.2 - 2026-08-29

### Added: static linking of C++ programs

- **`glibc-static` on Fedora and Rocky.** This was the actual gap. Fedora already carried
  `libstdc++-static`, Rocky carried neither, and Ubuntu was covered all along because
  `libc6-dev` ships `libc.a` and `libm.a` as part of `build-essential`. On the rpm images a
  `-static` build failed with `cannot find -lc`, which is a confusing error for something
  the package implied it supported.

- **Optional static archives and a musl toolchain**: `zlib`, `openssl` and `libcxx` static
  packages where the distribution provides them, plus `musl-gcc` on Ubuntu and Fedora, all
  as optional leaves so a renamed package logs a note rather than breaking the build.

- **Asserted at build time and again against the built image.** Every Dockerfile now links
  and *runs* a fully static C++ program that exercises `std::string` and `std::vector`
  before the image is considered good, and `smoke-test.sh` re-checks both `-static` and
  `-static-libstdc++ -static-libgcc`, then confirms with `file` that the result is really
  `statically linked` rather than merely compiled. A static library that is missing is
  otherwise invisible until a user's first attempt.

- **The toolchain report lists the static archives it finds**, by path, so
  `capabilities.sh` answers "can I link statically in this image" per image rather than by
  inference.

### Documented: the part that matters more than the packages

`docs/operating-guide.md` §7a and a README section explain that a fully static glibc binary
is **not portable in the way people expect**. glibc resolves hostnames and users through
NSS modules that are `dlopen`ed at run time, so a static binary calling `getaddrinfo` or
`getpwnam` still needs matching glibc shared objects on the target. The linker warns about
exactly this, and the warning was reproduced while writing the feature rather than quoted
from memory:

    warning: Using 'gethostbyname' in statically linked applications requires at
    runtime the shared libraries from the glibc version used for linking

Three options are given in the order they are usually right: `-static-libstdc++
-static-libgcc` first, because it removes the libstdc++ coupling that actually breaks
binaries between distributions while keeping NSS working; full `-static` when the program
does no name or user lookup; and musl when the target machine is genuinely unknown, with
the honest note that musl-gcc is a C toolchain and static C++ against musl would need a
musl-targeted libstdc++ these images do not ship.

## 2.3.1 - 2026-08-29

### Fixed

- **`GEMINI_DIR` does not exist; I invented it.** The Gemini CLI reads `GEMINI_CLI_HOME`,
  and treats it as the root *under* which it creates `.gemini`. So the variable added in
  2.2.0 to persist Gemini's state did nothing, and Gemini's logins and sessions were still
  thrown away on `--rm` while Claude's survived. `CODEX_HOME` and `GROK_HOME` were correct.

- **The agent home directories were named but never created.** Every build printed
  `codex WARNING: ... CODEX_HOME points to "/home/dev/.claude/agents/codex", but that path
  does not exist`, because the directories were created by the entrypoint at run time and
  the toolchain report runs at build time. They are now created in the image as well, and
  `smoke-test.sh` fails if a variable names a directory that is not there.

- **`doctor.sh`'s image-version check, added in 2.2.0, was never applied.** The edit
  matched `pass "$ref ...` while the code says `ok "$ref ...`, so the replacement silently
  did nothing and the check has never existed. This is the sixth defect in this project
  from a string replacement that reported success and changed nothing; it was found by
  grepping for the feature rather than trusting the changelog.

### Added

- **A failed `--from-registry` pull now explains itself and offers the local build.** It
  previously died with `could not pull a base image`, which leaves a first-time user stuck.
  It now names the likely causes -- not published yet, registry unreachable, or
  `AI_BOX_REGISTRY` pointing elsewhere -- prints the local build command, which needs no
  registry, and states the cost: 10-15 minutes for one image, about 35 for three.

- **The base image digest is logged on derive.** A tag is mutable, so deriving from a
  re-pushed tag was indistinguishable from deriving from a stale one.

- **`doctor.sh` reports when an image's agent has aged.** Deriving from a published base
  refreshes OS packages but not Claude Code, which comes from the signed repository baked
  into the base and is pinned by its tag. A base published two months ago carries a
  two-month-old agent even with `OS_UPDATES=1`, and nothing said so.

### Changed: README quick start

- **Where to extract the tarball.** The package runs from where it is extracted and
  `install.sh` only creates symlinks back to it, so extracting in `~/Downloads` and tidying
  up later breaks the installation. Says so, and suggests a stable location.

- **Installing for several users.** One copy under `/opt`, each user running `install.sh`
  once, per-user key stores and state. Says plainly that a key store and a state directory
  must not be shared, since they hold credentials and sessions, and notes the UID caveat:
  an image is built with the builder's UID, so users with different UIDs should derive
  their own image or use rootless Podman.

- **`--from-registry` is now the first thing offered**, with the local build beside it and
  the real cost of each. Measured, not estimated: `--agents all all` took 34 minutes on a
  laptop. A table says which single image to build, because `all` is rarely what a first
  run wants.

## 2.3.0 - 2026-08-28

### Fixed

- **"builds both images" and ten more phrasings from when there were two.** The README's
  quick start still said "both images"; so did `AGENTS.md`, `docs/upgrading.md`,
  `docs/operating-guide.md` and `scripts/build.sh`'s own help. The document-sync gate added
  in 2.2.1 looked only for the literal phrase "two images" and missed every one of them.

  The gate now matches "both", "either" and "two", scans every markdown file rather than
  the top four, and reads the image count from the README's own table so it cannot go stale
  in its turn. It is anchored on package-scope phrasing, because "one major behind the
  other two images" and "two images will fight over one build tree" are correct prose and a
  looser pattern flagged both.

### Added

- **`--lang`: optional language toolchains.** `rust`, `go`, `java`, `node`, `ruby`, `lua`,
  or `all`, at build time and on the derive path:

      scripts/build.sh --lang rust fedora
      scripts/build.sh --from-registry --lang rust,go all

  Per-distribution package names live in one table in `shared/install-langs.sh`, because
  the difficulty of this feature is precisely that the names differ and drift. They install
  as optional leaves, so a moved name logs a note rather than breaking the build, and the
  installer prints what actually landed -- a language whose packages were all skipped is
  otherwise a silent no-op. Unknown names are rejected before the build starts, and `c++`
  and `python` are accepted and ignored, since they are the base image.

  **The limits are deliberate and documented.** Distribution packages only. No upstream
  installers during a build: `curl https://sh.rustup.rs | sh` is the same category as the
  agent vendors' installers, which this project refuses, so distro toolchains lag and the
  documented answer for a specific Rust is to install rustup into the *project* at run
  time. Recorded as decision D11, including that this narrows the earlier "no Node
  toolchain for project work" non-goal rather than reversing it: still absent by default,
  no longer refused when asked for.

- **README says how the package was built.** ai-box was designed and written with AI coding
  agents, largely inside the container it produces, and the section says so where a reader
  will see it rather than burying it. It points at the changelog and the decision log,
  which record defects candidly, including several introduced by an agent editing code it
  could not execute, and notes that reviews by other agents from inside a built image found
  defects source review had missed. A tool for running agents safely should be honest about
  what working with agents costs.

- The toolchain report and capability table cover `rustc`, `cargo`, `go`, `javac`, `mvn`,
  `ruby` and `lua`, so `--lang` results are visible per image like everything else.

## 2.2.1 - 2026-08-28

### Added

- **`ai-box --version` / `-V`** prints the package version, the command's location resolved
  the way `ls -l` shows it, the package directory, the engine, the image tags and where to
  find newer releases:

      ai-box 2.2.1
        command   /home/you/.local/bin/ai-box -> /home/you/src/ai-box-v2.2.1/scripts/ai-box
        package   /home/you/src/ai-box-v2.2.1
        engine    docker (Docker version 28.x)
        images    ai-ubuntu:26.04 ai-fedora:44 ai-rocky:10
        releases  https://github.com/erez-strauss/ai-box/releases

  Both halves are printed because almost every installation is a symlink into a package
  directory, so "which version am I running" has two answers, and a stale symlink pointing
  at an older extracted tarball is a real way to be confused.

- **`ai-box -v`** runs the script under `set -vx`, echoing every line and expansion. It
  shows the exact argv before the engine sees it, which is what you want when the container
  starts but not the way you expected.

- **`ai-box --help` / `-h`** now ends with where things are: the command, the package and
  its version, the key store, the state directory, the README path, and the releases URL.
  It also gained a short examples block. Both `--version` and `--help` work with no engine,
  no keys and no images, since those are the commands you reach for when nothing else works.

- **`AGENTS.md`**, the canonical working agreement for anyone changing this package, agent
  or human. `CLAUDE.md` remains, because Claude Code reads that exact filename, and is now
  a pointer to it plus the Anthropic-specific notes. Keeping the agreement in one file is
  what stops the two drifting.

- **`check-doc-links.sh` verifies the three documents agree.** README, AGENTS and CLAUDE
  must cross-reference each other, and none may claim a number of images that contradicts
  the README's own table. The check found a stale "the two images differ" sentence on its
  first run.

- README gained a short "which document to read" table, because there are now four
  audiences: using it, changing it, working in a project inside it, and understanding why.

### Changed

- **`CONTRIBUTING.md` rewritten to be a welcome rather than a rulebook.** It opens with
  what ai-box is, points newcomers at `README.md`, suggests good first contributions, and
  says plainly that "this documentation confused me" is a useful report. The rules moved to
  where they belong: it now links `AGENTS.md` for the full agreement instead of leading
  with it. The one thing kept up front is that a patch widening what the container can
  reach needs an argument as well as code, with the reason.

## 2.2.0 - 2026-08-28

Closes the boundary, vendor and structural findings from two container-side reviews, plus
what a real build of all three images revealed.

### Changed: the mount guard

- **System trees are refused by prefix, not exact match.** `/etc` was refused while
  `/etc/ssh`, `/var/log`, `/root/.ssh`, `/opt/foo` and `/usr/local/src` were all accepted.
  That is precisely the by-hand case the README promises to refuse.
- **`refuse_under` canonicalises both sides.** `PROJECT_DIR` is resolved with `pwd -P`, so
  comparing it against an unresolved target let a symlinked store through: with `~/.aikeys`
  pointing at `/mnt/secrets/aikeys`, `-p /mnt/secrets/aikeys` passed every check.
- **`/tmp` and `/var/tmp` are refused as themselves, deliberately not by prefix.** Mounting
  all of `/tmp` hands over every host socket and scratch secret; a directory under it is an
  ordinary scratch project. Prefix-refusing would also have broken this package's own
  tooling, since `verify-isolation.sh` and `smoke-test.sh` build their probe workspace with
  `mktemp -d` there. The test suite caught that before it shipped.
- `.password-store` added to the credential directories.
- **`tests/mount-guard.test.sh`**: 35 assertions driven through `ai-box -n` rather than
  re-implementing the logic. Every row of the review's table is now a test.

### Changed: credentials and vendors

- **An unknown `kind:` is refused instead of defaulting to `ANTHROPIC_API_KEY`.** A typo
  silently produced an Anthropic variable, so the wrong credential outranked the right one
  and surfaced as a 401 from a vendor the key did not belong to. All six callers handle the
  refusal.
- **`grok` maps to `XAI_API_KEY`**, the name xAI documents; the older
  `GROK_CODE_XAI_API_KEY` stays on the allowlist.
- **`ai-keys test` dispatches on kind.** It sent every credential to
  `api.anthropic.com` with `x-api-key`, so a valid xAI or Google key returned 401 and was
  reported as "key rejected". Each kind now reaches its own vendor with the right header,
  still through a mode-0600 curl config so the secret stays out of `ps`.
- **`doctor.sh` uses the shared kind detection** instead of grepping for `sk-ant-`.
- **Optional agent state persists.** `GROK_HOME`, `GEMINI_DIR` and `CODEX_HOME` point
  inside the existing `~/.claude` mount, so their logins and sessions survive `--rm` as
  Claude's already did. No new bind mount.
- **The npm agents are pinned** rather than tracking `latest`, and an unset `CODEX_SHA256`
  now prints the digest to pin.

### Added: the gate the package did not have

Every check ran against the tree; none compared the tree to a built image. That is how the
shipped entrypoint kept telling users to read a document deleted two releases earlier while
`check-doc-links.sh` stayed green.

- **`smoke-test.sh` reads `docs/` references out of the image** and validates them against
  the tree, and fails when the image's `ai-box-package` does not match `VERSION`.
- **`doctor.sh` reports image package version against the wrapper**, with the rebuild
  command. It notes rather than fails: there are reasons to run an older image.
- **`verify-isolation.sh` half three goes through `ai-box -N none`.** It built its own
  engine invocation, so a wrapper that stopped passing `--network` would still have shown
  green. No direct engine call remains in that script.
- **`check-file-inventory.sh` excludes what `pack.sh` already excluded**: `.cache-*`,
  `.ccache-*`, `core.*`, `.claude/`, review and workplan files. Using the product on its own
  tree failed a CI-gated check. `.dockerignore` gained the same, so a populated ccache no
  longer enters the build context.
- **`shellcheck` is in all three images**, making definition-of-done item 2 reachable from
  inside the box, which is where this project intends work to happen.
- **`CLAUDE.md` records the host/container split**: what a containerised session can close,
  what must be handed to a host, and why writing the handoff down matters.

### Added: documentation

- **`docs/project-template.md`**, a `CLAUDE.md` to copy into a project opened in the box.
  It covers the four things agents reliably attempt and cannot do here: `sudo`, installing
  system packages, `pip install` into the system Python, and building in the source tree.
- The egress example lists the optional agents' hosts. An allowlist without them produces
  opaque network failures rather than a clear refusal.

### Corrected by the build evidence

- **Rocky has Clang 21.1.8.** The extra attempt added earlier worked; every "Rocky has no
  Clang" claim is gone. The remaining spread is a version difference, which D3a expects.
- **D3a now carries evidence that newest is not most conservative.** Ubuntu built GCC 16.0.1
  (a March trunk snapshot), Fedora GCC 16.2.1 (a release). A C++26 reflection program that
  compiles on Fedora fails on Ubuntu with `odr-used inline variable is not defined`. Same
  major version, different behaviour.
- Ubuntu's Dockerfile header said the image no longer needs apt.llvm.org, contradicting D3a
  and the README. It takes Clang from there by default, because the archive trails a major.
- `ai-box`'s header said the default image is Ubuntu; it has been Fedora for some time.
- `compose.yaml` now says it lacks `--userns=keep-id` and SELinux relabelling, and that
  there is no rocky service by choice.
- `CLAUDE.md` no longer offers `git log` as a peer context source: the released tarball has
  no `.git`, so the changelog is the durable record.

## 2.1.3 - 2026-08-28

First release after all three images were built and checked. Two external reviews were
written from inside a running box; this closes the findings that are defects in code that
had never executed.

### Fixed

- **`--node-only` never worked.** `ensure_node` called `have()` forty lines before it was
  defined, so `WITH_NODE=1` produced `have: command not found` twice and exited 0 without
  installing Node. Introduced in 2.1.0 when Node installation moved into
  `install-agents.sh`, and invisible because no image had been built since.

- **`build.sh` contained the `--from-registry` block twice.** The second copy sat after the
  from-source build loop, unreachable behind its `exit 0`. Introduced by the same edit that
  added the feature.

- **`toolchain-report.sh` probed `claude` twice**, so every image's report ended with a
  duplicate row. Visible in the build output of all three images.

- **`sudo` is removed from the Fedora image and its absence asserted in all three.**
  An isolation run confirmed what both reviews said: `sudo absent` FAILed on Fedora while
  Ubuntu and Rocky passed. Emptying `/etc/sudoers.d` removed the configuration and left the
  setuid binary. The escalation did not work -- `NoNewPrivs=1`, `CapEff=0` and an empty
  `sudoers.d` each blocked it independently -- so this was a false invariant rather than a
  live escape. The package's own position is that a guarantee resting on remembering a flag
  is not a guarantee, so the binary is gone and a post-`USER` build step now fails if a base
  image ever brings it back.

- **`stamp-version.sh` treated a rule that matches nothing as success.** Three of seven
  rules had matched nothing since the documentation was flattened and their headers deleted,
  so three documents went unstamped while the check stayed green. It now reports a dead rule
  as drift, and the headers are restored.

- **Three tools were reported `n/a` while being installed.** `clang-tidy` prints
  `LLVM (http://llvm.org/):` before its version, so taking the first line captured a URL;
  `lcov` can emit a perl warning first; and `iwyu` is `include-what-you-use` on Fedora, a
  name the capability table never looked for. All three now resolve.

### Added

- **A warning when state is left under the pre-2.0.0 path.** The compatibility fallback was
  removed in 2.1.1, so anything under `~/.local/share/claude-box` is no longer read and the
  agent silently asks for a fresh login. The isolation run showed exactly this for the
  Ubuntu and Rocky images. The wrapper now says so once, with the command to move it.

### Note

Rocky now has Clang 21.1.8. The extra attempt added in 2.0.8 worked, and the documentation
that says the image has no Clang is stale; that is corrected in the next release along with
the rest of the documentation pass.

## 2.1.2 - 2026-08-19

### Added

- **Host-side scripts refuse to run inside an ai-box image.** `ai-box`, `build.sh`,
  `upgrade.sh`, `check-updates.sh`, `capabilities.sh`, `verify-isolation.sh` and
  `smoke-test.sh` now say so plainly instead of failing later with
  `required tool not found: docker`. This matters because the project recommends running
  an agent in the box on a checkout of itself, so an agent will try exactly this.

  The check asks **"am I inside an ai-box image"**, never "am I inside a container". The
  generic question is unreliable -- `/.dockerenv` is Docker only, `/run/.containerenv` is
  Podman, cgroup parsing broke with cgroup v2 -- and gating on it would be wrong anyway,
  because CI runners are frequently containers and building images from one is legitimate.
  It requires **both** `AI_BOX_IMAGE` and `/etc/toolchain-versions`: the variable alone
  could come from a shell profile, and the file alone would match an image someone derived
  from ours.

- **`install-agents.sh` refuses to run outside the image build.** It installs system
  packages, writes to `/usr/local/bin` and runs `npm install -g`, so on a host it modifies
  the host. An earlier version of that same file also ran `rm -rf /tmp/*` and deleted a
  working directory when invoked by hand during a verification.

  The guard is **explicit intent, not detection**: only the Dockerfiles set
  `AI_BOX_BUILD`. Marker-file detection was written first and rejected during testing,
  because a host that has ever had `toolchain-report.sh` run on it acquires
  `/etc/toolchain-versions` and thereafter looks like an image -- which is exactly what
  happened on the machine used to test the guard, so it did not fire.

- **The engine failure now says why.** `require_engine` distinguishes a missing binary, a
  daemon that is not running, and a socket the user cannot reach, and gives the fix for
  each: `systemctl start docker`, or `usermod -aG docker` with the note that docker group
  membership is equivalent to host root.

- **Podman is offered as a fallback, with the caveat that makes it usable.** If Docker is
  unavailable and Podman is present, the message says so *and* explains that Podman keeps
  images in its own store, so images built with Docker are not visible to it. It gives
  both ways forward: rebuild with `AI_BOX_ENGINE=podman`, or copy across with
  `podman pull docker-daemon:<image>` while the Docker daemon is still reachable. A bare
  "try Podman" would have sent people straight into "image not built".

## 2.1.1 - 2026-08-19

### Removed

- **Every trace of the `claude-box` name, and the compatibility layer with it.**
  `scripts/migrate.sh` and `scripts/legacy-shim.sh` are gone, along with the legacy
  environment variables, the directory fallbacks, the `.claude-profile` fallback and the
  duplicate `/run/secrets/claude-key` mount. Only vendor-owned names remain, which are not
  ours to change: `CLAUDE.md`, the `claude` command, the `claude-code` package,
  `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN` and `~/.claude` inside the container.

  **This is a breaking change for anyone whose state is still under the old names.** There
  is no longer a fallback, so a stored login left in `~/.local/share/claude-box` will not
  be found and the agent will ask you to log in again. Run `ai-box-migrate` from 2.1.0
  *before* upgrading, or move the directories by hand.

- **`examples/`.** The two C++26 reflection programs existed to give `smoke-test.sh`
  something to compile. The smoke test now writes every source it needs into the
  container's tmpfs, so it carries its own fixtures, mounts nothing from the package, and
  the reflection probe still runs. Removing them also removes the confusion of an
  `examples/` directory that was never an example of how to use the tool.

### Added

- **GitHub Actions**, three workflows. `ci.yml`: lint, unit tests, the four self-checks,
  the version-stamp check, a credential grep, and a labelled or scheduled image matrix that
  builds all three images and runs isolation and smoke on each. The weekly schedule is the
  point of it, not an afterthought: it is what catches a distro renaming a package or an
  agent vendor changing its install method before a user does. `release.yml`: refuses to
  publish unless the tag, `VERSION` and the changelog agree, then attaches the tarball and
  `SHA256SUMS` with that version's notes. `publish-images.yml`: publishes the three base
  images to GHCR on a tag, **without optional agents**, verifying isolation and smoke
  before pushing.

  Also `dependabot.yml` (Actions only, with a note on why base images are excluded), a pull
  request template whose checklist is the definition of done, two issue templates that warn
  against pasting credentials, and `.hadolint.yaml` recording why package versions are
  deliberately unpinned.

- **`org.opencontainers.image.source` on every image.** Without it a published package on
  GHCR has no README, licence or provenance link.

### Changed

- **`CONTRIBUTING.md` rewritten.** It now explains that a patch widening the mount surface
  will be asked for a justification most projects would not ask for, and tabulates which
  shipped defect caused each self-check to exist, so a contributor understands why working
  around one is not welcome.

  Kept as `CONTRIBUTING.md` rather than `CONTRIBUTE.md`: GitHub only recognises the former,
  and links it from the new-issue and pull-request pages. The file being findable matters
  more than its exact name.

## 2.1.0 - 2026-08-19

Publishing the base images without agents, and adding them locally.

### Added

- **`scripts/build.sh --from-registry`**: pull a published base image, apply package
  updates, install the agents from `--agents`, remap the user to your UID, and tag it
  locally under the usual name. Seconds instead of a full build, and `ai-box` needs no
  changes because the resulting tag is identical.

  Published images carry **no optional agents**, deliberately: a public image containing
  four vendors' CLIs is a redistribution question each vendor's terms answer differently,
  and most people want one agent. The published artifact is the expensive part; the derive
  step is the cheap part.

- **`docker-derive/Dockerfile.derive`**, which does the deriving. It defines no entrypoint,
  no user creation and no cache layout, inheriting all of it from the base, so
  `check-image-parity.sh` skips it rather than holding an overlay to the full contract.

- **UID remapping in the derive step.** A published image is built with a fixed UID; a user
  whose UID differs would find every file the agent writes owned by someone else on the
  host. The derive step remaps the user and re-owns the home directory, `/opt/venv`,
  `/opt/toolchains` and `/workspace`. A no-op when they already match. This is the
  problem publishing creates that building from source never had.

- **`scripts/upgrade.sh --from-registry`** to refresh a derived image. It reads the agents
  back from the `com.ai-box.agents` label so a refresh does not silently drop them.

### Changed

- **Node installation moved out of the Dockerfiles into `shared/install-agents.sh`.** A
  derived build must install Node the same way a from-source build does, and duplicating
  distro detection would have guaranteed the two drifted. One implementation, used by
  both, with `nodejs-full-i18n` still named explicitly on rpm distros. `--node-only`
  covers `WITH_NODE=1` with no agents.

### Fixed while implementing

- `--pull` collided with the existing `-p/--pull`, which means "refresh the base of a
  from-source build". The new flag is `--from-registry`; shellcheck caught the collision.
- `registry_ref` concatenated a repository with an already-tagged reference and produced
  `ai-fedora:44:2.1.0`, which is not a valid image reference. The distro version stays in
  the repository name and the tag is the package version.

### Not done

No image has been published, and the derive path has not been run against a real registry.
The reference format, the fallback to `:latest`, and the agent-preserving refresh were
exercised against a stubbed engine only.

## 2.0.14 - 2026-08-19

### Fixed

- **Seven scripts were in the package and never installed.** `install.sh` kept a
  hand-maintained list, and every edit adding to it since 2.0.5 matched a slightly
  different line wrapping and silently did nothing. `capabilities.sh`, `doctor.sh`,
  `migrate.sh` and the four `check-*` scripts were therefore never linked onto anyone's
  PATH — `ai-box-capabilities` did not exist as a command, despite being documented.

  `install.sh` now **discovers** the executables in `scripts/` instead of listing them,
  with a short exclusion list carrying its reasons (`lib-common.sh` is sourced,
  `legacy-shim.sh` is linked under its old names, `install.sh` and `pack.sh` are
  maintainer commands). A list can drift; discovery cannot. Locked by tests that assert
  the expected names exist and that the sourced library is not linked.

  This is the fifth defect from a string replacement that silently matched nothing. The
  pattern is now well enough established to state plainly: in this package, an edit that
  reports success is not evidence that anything changed.

### Changed

- **`ai-box-capabilities` reports AI agents in their own section**, with versions, rather
  than mixing them into the tool table:

      AGENT     ubuntu        fedora        rocky
      claude    2.1.227       2.1.227       2.1.227
      codex     0.148.0       0.148.0       n/a
      gemini    n/a           0.55.1        n/a
      grok      n/a           1.0.5         n/a

  "Which agents does this image have, and at what version" is the question people
  actually ask, and burying `grok` between `pytest` and `patchelf` hid the answer. Agents
  other than `claude` appear only when the image was built with `--agents`. Both the plain
  and `--markdown` forms have the section.

## 2.0.13 - 2026-08-19

### Fixed

- **graphviz, doxygen and the binutils tools were installed but invisible.** All three
  went into the images in 2.0.11 (`readelf`, `objdump`, `nm`, `addr2line`, `strings`,
  `size` all ship in `binutils`), but the edit that was supposed to add them to
  `shared/toolchain-report.sh` matched nothing and silently did nothing, so
  `/etc/toolchain-versions` never mentioned them and `capabilities.sh` could not show
  them. The same edit was also meant to add `cppcheck`, `lcov`, `gcovr`, `iwyu`,
  `clang-tidy` and `clang-format`; none of those were reported either.

  An installed tool nobody can discover may as well not be installed, particularly for an
  agent working in the box, which finds out what it has by reading that file.

  The report now probes all of them by name — `readelf`, `objdump` and `nm` individually
  rather than hiding behind "binutils", since those are the names people reach for — and
  `capabilities.sh` lists them.

- **`dot` does not accept `--version`.** It wants `-V`, and printed an error line into the
  report. The probe now special-cases it.

### Added

- **`check-image-parity.sh` fails when a tool the images install is not probed by the
  report.** This is the fourth defect in this project caused by a string replacement that
  silently matched nothing (after the version stamp, `GCC_DEFAULT`, and the renamed
  documentation references). Each is now covered by a check that fails loudly. Verified by
  removing the binutils entries: the check names exactly the four tools that went missing.

- **The build notes when `readelf`, `objdump` or `nm` are absent**, since `binutils` is in
  the optional group and a missing one should be visible rather than discovered later.

## 2.0.12 - 2026-08-19

### Changed

- **`docs/ai-box-project-roadmap.md`: every external project now carries a link, and each
  one was checked.** 29 of 31 return 200; `containers.dev` and `modelcontextprotocol.io`
  return 403 to a scripted request because of bot protection and work in a browser, which
  the document says rather than leaving a reader to wonder. Two upstream issues that each
  cost this project a release are cited: nodejs/node#51752 and moby/buildkit#5943.

- **The MCP section is rewritten around the two-service decomposition**: a *package*
  service (query, build, start) and an *instance* service (run commands in a box that
  already exists).

  The earlier draft sorted tools into read-only and mutating. That is the wrong cut. The
  invariant is **who chooses the mount surface**, and by that test the instance service is
  the safest component in the design rather than the most dangerous: an instance started
  by a human has already had its mounts, capabilities and credential fixed, so a tool that
  runs commands inside it cannot change any of them.

  Two tools are dangerous and are constrained rather than dropped. `start_instance` must
  never accept a path — it takes a name from a registry the human populated, because the
  guard in `ai-box` protects a human's command line, not an MCP call. `build_image` is
  subtler: a build context is a host path and BuildKit can `COPY` anything out of it, so a
  free-form context parameter is an arbitrary host-file read wearing the costume of a build
  verb.

  The section now leads with the reachability rule, since it decides everything else: both
  services run on the host, hold host authority, and must be unreachable from inside a box
  — otherwise an agent in a box requests an instance mounting `/` and the containment is
  theatre. Worked example: a host agent driving a boxed agent, with different credentials
  and different blast radii. Includes the observation that `exec` bypasses the entrypoint,
  so the host agent can drive builds inside a box without inheriting the boxed agent's
  key, which is worth pinning with a test.

  Adds `dagger/container-use` to the comparison as the closest existing prior art, and
  records the open consequences: concurrent writers to one workspace, and audit logging.

## 2.0.11 - 2026-08-19

### Added

- **C++ verification and analysis tooling in all three images**, as optional packages so a
  renamed leaf cannot break a build: `cppcheck`, `lcov`, `gcovr`, `include-what-you-use`,
  `elfutils`, `nlohmann-json`, `eigen3`, `doxygen` with `graphviz`, `binutils` and
  `patchelf`. `clang-tidy` and `clang-format` were already present through the Clang
  packages. `gcovr` is also in the Python set, so coverage works even on an image whose
  distribution does not package it.

  `toolchain-report.sh` and `capabilities.sh` report them, so the per-image table shows
  which analysis tools an image actually has rather than which were requested.

- **`docs/ai-box-project-roadmap.md`**: proposed next steps from a whole-tree read, a
  strategic comparison with the Anthropic dev container, claudebox, the Dev Containers
  spec, microVM sandboxes, Nix and hosted environments, candidate tooling, and the
  question of an MCP server.

  Two conclusions worth surfacing here. The credential model is the thing this package
  does better than the alternatives; unrestricted egress is the thing it does worst, and
  it is what every reviewer notices first. And on MCP: read-only tools
  (`list_images`, `image_capabilities`, `check_updates`) are useful and safe, while
  mutating ones (`build_image`, `run_in_box`) should not exist, because an agent that can
  start containers chooses their mounts and thereby defeats the wrapper.

## 2.0.10 - 2026-08-19

### Added

- **`docs/ide-clion.md`**: using these images from CLion for edit, build, run and debug.

  The substance is where CLion's model and this project's differ. CLion's Docker toolchain
  starts and manages its *own* container from the image, so none of the hardening `ai-box`
  applies is present unless it is added in Container Settings, and the credential store
  must stay out of it. The document says so plainly rather than presenting the two as
  equivalent.

  It also documents a trap these images create for any tool that bypasses the entrypoint:
  `CCACHE_DIR` and `XDG_CACHE_HOME` point into `/workspace`, and CLion mounts the project
  somewhere else, so caches are written into the ephemeral container layer and `~/.cache`
  can dangle. The symptom is builds that are never incremental and confusing `pip` cache
  errors. The fix is two environment variables in the CMake profile, or a named volume.

  Per-image notes where they matter: Rocky's compilers are under `/opt/rh/toolset`, so
  CLion detecting `/usr/bin/gcc` there has found the older system compiler; Rocky
  currently has no Clang; `--cap-add=SYS_PTRACE` is required for breakpoints and
  `seccomp=unconfined` for address-space randomisation. Includes a Dev Containers
  alternative, which can honour `/workspace` and therefore avoids the cache trap.

## 2.0.9 - 2026-08-19

### Fixed

- **Six references to `docs/api-keys-headless-v1.md`, a file that no longer exists.**
  Flattening the documentation for publication renamed it to `docs/credentials.md`, but
  that pass only rewrote `.md` files. The references left behind were in scripts, a
  Dockerfile and a config example, and two of them are printed to the user at runtime: the
  container's first-run banner and an `ai-box` error message both told people to read a
  document that was not in the package. No content was lost; the file was renamed, not
  removed.

- **`stamp-version.sh` skipped rules naming a missing file, in silence.** Three of its
  seven rules pointed at the pre-rename document names and had therefore been doing
  nothing. It now reports a rule that names a file which is not there and treats it as
  drift, so a rename cannot quietly disable the version stamp again.

### Added

- **`scripts/check-doc-links.sh`**: every `docs/…` path mentioned anywhere in the package
  must exist. `check-file-inventory.sh` catches a file with no row in the README table;
  this catches the opposite, a reference to a document that is not there. It names the
  referencing file, and `pack.sh` runs it, so a broken link cannot ship. The changelog is
  excluded, since it is a historical record and legitimately names files that have moved.

## 2.0.8 - 2026-08-19

Applies the toolchain policy consistently and writes it down where users and agents will
find it.

### Changed

- **"Newest available" now means newest *obtainable*, not newest packaged by the
  distribution.** The policy was applied to GCC and not to Clang, which is why a build
  produced Ubuntu with GCC 16 but Clang 21 while Fedora had Clang 22. Ubuntu now takes
  Clang from apt.llvm.org by default, because the archive trails a major version.

  `--toolchain distro` is the opt-out: it restricts an image to its distribution's own
  signed repositories, which is one fewer third-party signing key at the cost of an older
  Clang. Some supply-chain policies require that; the default no longer assumes yours
  does. `-L`/`-l` still override explicitly, and `-g VERSION` still pins a GCC.

- **The upstream LLVM path degrades instead of failing.** If apt.llvm.org has no packages
  for a codename yet, the build installs the archive Clang, says so, and continues. An
  image that cannot get the newest is still a working image; a failed build is not.

- **Rocky tries harder for Clang before giving up.** When no `llvm-toolset` resolves it now
  attempts the base repositories explicitly rather than relying on a `--skip-unavailable`
  pass that could swallow the failure silently, and reports plainly when the release
  genuinely has none.

### Documentation

The policy is now stated in three places, deliberately, because three different readers
need it: `README.md` for someone choosing an image, decision D3a in
`docs/design-decisions.md` for someone changing the design, and hard rule 10 in
`CLAUDE.md` for an agent working on the package. D3a also records what counts as an
obtainable source (distro repositories, first-party upstream repositories for the compiler
itself, RHEL Software Collections — each with a signature the build verifies), that newest
is not the same as most conservative, and that no image is ever held back so the three
match.

The README header also still said "Two images" and described toolchains that predate the
third; it now describes what actually ships.

## 2.0.7 - 2026-08-19

First release after a successful build of all three images. The reported toolchains
prompted two corrections and one policy being written down.

### Fixed

- **Every Ubuntu image was pinned to GCC 15 despite the documented default being the
  newest installed.** The Dockerfile default was `GCC_DEFAULT=latest` and the resolution
  logic worked, but `build.sh` kept its own `GCC_DEFAULT="${AI_BOX_GCC_DEFAULT:-15}"` from
  before that change and passed it as a build arg unconditionally, so the Dockerfile's
  default was never reachable. `build.sh` now passes the arg only when the caller asks for
  a specific version, and the Ubuntu build asserts that `gcc -dumpversion` matches what was
  resolved, so a silent wrong default becomes a failed build.

### Added

- **Decision D3a: newest available per image; identical versions are not a goal.** Each
  image ships the newest toolchain its distribution offers, and the three are expected to
  differ. Hard rule 10 is about the contract — entrypoint, user, paths, variable names —
  and `check-image-parity.sh` deliberately says nothing about which compilers are present.
  A common subset is a convenience, not a requirement, and no image is ever held back to
  match another.
- **`scripts/capabilities.sh`**, which reads `/etc/toolchain-versions` out of each built
  image and prints one table, plain or `--markdown`. Because the images differ by design,
  what each contains has to be discoverable rather than assumed.

### Known difference

Rocky currently has no Clang, where Ubuntu has 21 and Fedora has 22. Under D3a a version
difference is expected; a complete absence is worth one more attempt, so checking whether
`llvm-toolset` is resolvable on Rocky 10 with CRB enabled is recorded as open work. Until
then the difference is visible in `capabilities.sh` rather than left to be discovered.

## 2.0.6 - 2026-08-19

### Fixed

- **Gemini segfaulted at startup on the Fedora image, and the cause was in this project.**
  A core dump symbolised to `v8::internal::JSSegments::Create`, reached from
  `Intl.Segmenter.prototype.segment`.

  These images install with `--setopt=install_weak_deps=False`, which is right for keeping
  an image lean but drops `nodejs-full-i18n` — a *weak* dependency of `nodejs` carrying the
  ICU break-iterator data. On such a build `new Intl.Segmenter()` succeeds and the first
  `.segment()` call dereferences a null `icu::BreakIterator*` inside V8. That is a native
  SIGSEGV: no JS stack, nothing to catch, and a several-hundred-megabyte core dump in the
  project directory. It is upstream nodejs/node#51752, whose reproduction is the same dnf
  invocation this project used.

  Agent TUIs use `Intl.Segmenter` to measure grapheme widths, so any of them would have hit
  it; Gemini was simply the one that got run.

  `nodejs-full-i18n` is now installed explicitly on Fedora and Rocky. `install-agents.sh`
  refuses to finish if `Intl.Segmenter` does not work, naming the package to install, and
  `smoke-test.sh` checks the same thing plus `--version` for whichever optional agents an
  image actually contains — so `--agents all` now has a definition of done.

  Nothing about the sandbox contributed to this. Capabilities, seccomp and the mount
  surface were never involved.

## 2.0.5 - 2026-08-19

Package renamed from `ai-isolate` to `ai-box`, matching the command. Documentation
flattened to describe the current state rather than the path taken to it. Acts on an
external review (findings F1-F19 in that review) and on two problems reported from real
use.

### Fixed

- **A stored login was not found after the rename, so the agent asked to log in again.**
  State directories are named after the image reference, and the rename changed it
  (`claude-fedora:44` to `ai-fedora:44`). There was a fallback for this, but at the wrong
  level: it fired only when the whole state *root* was missing, and `install.sh` creates
  that root. After installing, the root existed, the fallback stopped firing, and the
  per-image directory under it was empty. The fallback is now resolved per image and looks
  in both the current and the previous root. Covered by a test.
- **`.ai-profile` only refused Anthropic credentials.** A `xai-`, `sk-proj-` or `AIza` key
  pasted into that file — which is designed to be committed — passed the guard. It now
  refuses anything the key parser recognises as a credential of any vendor.
- **The companion key `.env` was sourced.** The host config file is parsed with an
  allowlist precisely because a file that can execute code sits on the credential side of
  the boundary; the `.env` in a key profile is the same class of file and was being run as
  shell. It is now parsed with an allowlist and unknown names are reported and ignored.
- **The isolation probe rebuilt its own hardening flags.** Half of `verify-isolation.sh`
  parses `ai-box -n`, but the probe container was constructed by hand, so a wrapper that
  added a bind after printing `-n` would have passed both halves. The probe now runs
  through `ai-box` itself, which also exercises the real entrypoint.
- **`compose.yaml` bound ccache onto `/home/dev/.cache/ccache`**, which is a symlink into
  the workspace; binding a volume there creates an anonymous volume that shadows the target
  and discards the cache. The binds are gone and the file explains why. Its stale
  `GCC_DEFAULT: "15"` override is gone too.
- **`channel_candidate` had no Rocky arm**, so update checks reported "unknown" for that
  image and `upgrade.sh` could not pin its version. Rocky uses the same signed dnf
  repository as Fedora; it now shares that path.
- **Leftovers could block a release.** Running the box against a checkout leaves
  `.cache-*`, `.ccache-*` and possibly a core dump in it, which then failed the inventory
  and pack gates. They are in `.gitignore` and in `pack.sh`'s exclusion list.

### Added

- **`tests/`**: 47 assertions over the key parser and the shared library, run by
  `tests/run.sh`. Both historical parser bugs are named cases, as are the state fallback
  above, hostname derivation, profile precedence and the credential guard. Ships in the
  tarball.
- **`AI_BOX_IMAGE` is exported into the container**, so project conventions can key off it
  (`build/$AI_BOX_IMAGE-gcc`, `.venv-$AI_BOX_IMAGE`) without the name being written by
  hand. Not a credential, not a mount; the same string is already in the hostname.
- **`CODEX_SHA256`** build arg: empty prints the digest, set makes a mismatch fatal.

### Changed

- Optional agents fail the build when `--version` does not work, rather than being
  installed and hoping. A silently broken agent in an image is worse than a failed build.
- `TZ` defaults to UTC and is a build arg. It was one maintainer's local zone.
- Documentation flattened for publication: files have stable names
  (`operating-guide.md`, `credentials.md`, `upgrading.md`, `design-decisions.md`), and
  release-number archaeology is gone from the prose. Design decisions and open work are
  stated as the current position, with the reasoning kept and the chronology dropped.
- `CLAUDE.md` said the package builds two images; it builds three, and the definition of
  done now requires isolation and smoke tests for all three plus the unit tests.

### Not done, deliberately

No image was built for this release. Building all three from a cold cache remains the
first item of open work, and every image-level claim here should be read as untested.
Findings that depend on that build — proving the optional agents, the Gemini crash report,
the capability matrix — are recorded in `docs/design-decisions.md` rather than guessed at.

## 2.0.4 - 2026-08-19

### Fixed

- **The documentation still claimed version 1.6.2.** Every release since then shipped a
  README whose header said `**Version:** 1.6.2` and whose quick start told the reader to
  extract `ai-isolate-v1.6.2.tar.gz` -- a file that does not exist -- and to tag
  `git tag v1.6.2`. Two doc headers were stale at 1.6.1 as well.

  Two causes, both process rather than typo. The version was stamped into prose by hand,
  and each release updated it by searching for the *assumed* previous value; when that
  assumption was wrong the replacement silently did nothing and reported success. And no
  release gate ever compared the documentation to the `VERSION` file, so nothing noticed
  for eight releases.

### Added

- **`scripts/stamp-version.sh`**, which owns every place the current version appears in
  the documentation. `--check` reports drift and exits non-zero; `pack.sh` runs it, so a
  stale stamp can no longer ship. It is deliberately narrow -- four anchored patterns in
  the README and one header per document -- because prose like "since 1.6.2 the caches
  live in the workspace" is history and must not be rewritten. A blanket version
  substitution across the docs would corrupt the changelog's own meaning.

  Worth recording: on its first run the stamper damaged the example showing two releases
  extracted side by side, collapsing bothversions to the current one and destroying the point
  of the example. It was caught by diffing the file rather than trusting the tool. That
  example now uses `OLD`/`NEW` placeholders that no stamper can match.

### Documentation

- `build.sh --help` described `-g` as defaulting to 15 (it has resolved to the newest
  installed GCC since 1.7.0) and omitted jinja2, numpy and pandas from the
  `--python-tools` default.

## 2.0.3 - 2026-08-19

### Fixed

- **`shared/install-agents.sh` ended with `rm -rf /root/.npm /tmp/*`.** Inside an image
  build that is merely untidy -- it deletes whatever else a build has put in `/tmp` --
  but the script is also runnable by hand, and there it destroys other people's files.
  It did exactly that here: a verification run of the 2.0.2 tarball deleted the directory
  the tarball had been extracted into, and a stub binary a test depended on, which then
  showed up as a second, phantom failure. Now only npm's own directories are removed.
- `install_codex` removes its temporary directory on any exit from the function, not only
  on the success path.

### Verified

The 2.0.1 feature was re-checked from the packed artifact rather than the working tree:
`all` expands to `codex,gemini,grok`; `all`, `none`, a single agent and a list each reach
`--build-arg AI_AGENTS`; a plain build passes no agent argument at all; an unknown name is
rejected before the build starts; `claude` is tolerated with a note; and the Dockerfile's
Node condition returns yes for `all`, `gemini`, `grok` and no for empty, `codex`, `none`.

## 2.0.2 - 2026-08-19

### Fixed

- **The Rocky image did not build.** It failed at the user-creation step with
  `/bin/sh: line 1: VIRTUAL_ENV: unbound variable`. Ubuntu and Fedora were unaffected.

  The Rocky Dockerfile was scaffolded in 1.7.0 by copying the Fedora one and replacing
  the region between the toolchain section and the Claude Code section. That region
  turned out to span two more blocks than intended, so the copy silently lost the
  **Python virtualenv** (`ENV VIRTUAL_ENV`, `ARG PYTHON_TOOLS`, numpy/pandas/Jinja2) and
  the **build-time sanity check** -- while keeping a later line that interpolates
  `${VIRTUAL_ENV}`. Under `set -u` that is a fatal unbound variable, several minutes into
  the build.

  Both blocks are restored, adapted where Rocky genuinely differs:
  - the compilers are exercised by absolute path (`/opt/rh/toolset/bin/g++`), because the
    `ENV` block that puts the toolset on `PATH` comes later in the file; testing `gcc`
    there would have silently tested RHEL's older system compiler instead;
  - clang is optional, since `llvm-toolset` is installed with `--skip-unavailable` and
    its absence on a given release is a documented outcome, not a failure.

  So the Rocky image previously had no Python environment at all. It has one now, on the
  same terms as the other two.

### Added

- **`scripts/check-image-parity.sh`**, because hard rule 10 -- the images must be
  behaviourally equivalent -- was prose, and prose does not fail a build. It asserts that
  every Dockerfile defines the markers of the shared contract (entrypoint, key library,
  workspace, cache variables, unprivileged sanity check, the explicit `install -d` from
  rule 20) and that no Dockerfile interpolates a `${VAR}` it never declares. Verified by
  reintroducing the 2.0.0 defect: it reports the three missing blocks and
  `uses ${VIRTUAL_ENV} but never declares it`, which is exactly the line the build died
  on. Added to the definition of done and linked by `install.sh`.

### Note

Still not built here; no Docker in the environment where this was prepared. The parity
check is a structural test, not a substitute for `scripts/build.sh rocky`.

## 2.0.1 - 2026-08-19

### Added

- **`--agents all`**, expanding to every agent `shared/install-agents.sh` knows how to
  install. The list lives in that one file, so `all` follows it as agents are added
  instead of being kept in step by hand. `--agents none` is accepted as the explicit
  form of the default.
- **Agent names are validated before the build starts.** A typo previously surfaced
  partway through an image build; it now fails immediately with the list of valid names.

### Fixed

- **`--agents all` would not have installed Node.** The Dockerfile decides whether to
  pull in Node by matching `*gemini*|*grok*` against the requested list, and the literal
  string `all` matches neither -- so `gemini` and `grok` would have failed inside the
  image with "distributed only as an npm package, but Node is not in this image". The
  condition now also matches `all`.

### Documentation

- README states plainly that no optional agent is installed by default, and shows the
  three independent layers that enforce it, after the question came up.

## 2.0.0 - 2026-08-19

Renames the project and its commands from `claude-box` to `ai-box`. The box now holds
whichever agents you build into it -- Claude Code always, plus optional `codex`, `gemini`
and `grok` since 1.7.0 -- so a name promising a single vendor had stopped describing it.

### Why 2.0.0

Renaming every command, image, environment variable and state directory breaks an
existing workflow, which is the definition of MAJOR at the top of this file. The rule is
followed here rather than excepted: D2 (the `/work` -> `/workspace` rename shipped as a
PATCH) was the one knowing exception, and its own entry said the next such change would
not have that excuse. Recorded as decision D3 in `docs/roadmap.md`.

Note that the break is soft in every direction -- legacy command shims, legacy
environment variables, legacy directory fallback, legacy key mount points, and a
migration script -- so an un-migrated setup keeps working. The major bump reflects the
scale of the rename, not a cliff on upgrade day.

### Changed

- `claude-box` -> `ai-box`, `claude-keys` -> `ai-keys`.
- Images `claude-{ubuntu,fedora,rocky}` -> `ai-{ubuntu,fedora,rocky}`; Dockerfiles renamed
  to match.
- `CLAUDE_BOX_*` -> `AI_BOX_*`, `CLAUDE_KEYS_DIR` -> `AI_KEYS_DIR`.
- `~/.claudekeys` -> `~/.aikeys`; `~/.config/claude-box` -> `~/.config/ai-box`;
  `~/.local/share/claude-box` -> `~/.local/share/ai-box`.
- `.claude-profile` in a project -> `.ai-profile`.
- Container-internal: `/run/secrets/claude-key{,-env}` -> `/run/secrets/ai-key{,-env}`,
  `/usr/local/lib/claude-box` -> `/usr/local/lib/ai-box`, labels `com.claude-box.*` ->
  `com.ai-box.*`, the named volume `claude-toolchains` -> `ai-toolchains`.
- Package and tarball `claude-isolate` -> `ai-isolate`. Key-file library functions
  `claude_key_*` -> `aibox_key_*`.
- `docs/upgrading-claude-code-v1.md` -> `docs/upgrading-agents-v1.md`;
  `docs/claude-isolate-v1.md` -> `docs/ai-isolate-v1.md`.

### Deliberately NOT renamed

These names belong to Anthropic. Renaming them would break the product rather than
rebrand the wrapper, and the rename script protects them explicitly:
`CLAUDE.md` (Claude Code reads that exact filename), the `claude` command, the
`claude-code` package and its signed repository, `CLAUDE_CONFIG_DIR`,
`CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
`ANTHROPIC_API_KEY`, `~/.claude` and `.claude.json` inside the container, and the
`--claude-version` build flag, which pins that vendor's product specifically.
Historical entries in this file and in `docs/merge-1.6.0.md` keep the old names, because
they are a record of what the files were called at the time.

### Added

- **`scripts/migrate.sh`**, dry run by default, `--apply` to act. It handles the one case
  the runtime fallback cannot: per-image state directories are named after the image
  reference, and the reference changed, so `claude-fedora_44` would otherwise sit
  unreferenced while a new empty `ai-fedora_44` was created -- an apparently lost login.
  It never deletes an old image and refuses to merge when both old and new exist.
- **`scripts/legacy-shim.sh`**, which `install.sh` links as `claude-box` and `claude-keys`.
  It prints one deprecation line naming the new command, then forwards. A silent alias
  would be friendlier for a week and worse afterwards.

### Compatibility

Nothing breaks if you do nothing:

- `CLAUDE_BOX_*` and `CLAUDE_KEYS_DIR` are still honoured when the `AI_BOX_*` equivalent
  is unset.
- Each of the three state directories falls back to its old location when the new one
  does not exist.
- `.claude-profile` is read when `.ai-profile` is absent.
- The entrypoint reads `/run/secrets/claude-key` as well as `/run/secrets/ai-key`, and
  `ai-box` mounts the credential at both paths, so a new wrapper works with an image
  built before the rename and vice versa. Both are one line to delete once every image
  in use has been rebuilt.
- Using any of the above prints a single `warn:` line naming what to change.

### Also fixed

- **`scripts/pack.sh` shipped 1.7.0 without `docker-rocky/`.** The member list is an
  allowlist, and the new image directory was never added to it. The script did notice,
  and logged `not shipped (not part of the package): docker-rocky` -- but a `log` line in
  a build that prints hundreds is not a check, so a whole image went missing from a
  release. `docker-rocky` is now in the list, and anything present in the tree but in
  neither the ship list nor an explicit `NOT_SHIPPED` list is now a hard error. The
  1.7.0 tarball should be considered incomplete: rebuild from 1.8.0 to get the Rocky
  image.

### Also fixed (agents)

- **`install-agents.sh` resolved the codex version through `api.github.com` alone.**
  That endpoint rate-limits unauthenticated callers per source IP, so a CI runner or a
  NAT-ed office would hit `API rate limit exceeded` and the build would fail with an
  empty tag and no explanation. It now resolves through the non-API `/releases/latest`
  redirect first, falls back to the API, and when both fail says which happened and
  prints the exact `CODEX_VERSION=` pin to use instead. It also echoes the resolved
  version so a reproducible build can pin it.

### Verified against the real registries

The agent install paths were checked against live sources rather than documentation:

- npm names all resolve: `@google/gemini-cli` 0.55.1, `@xai-official/grok` 1.0.5,
  `@openai/codex` 0.148.0.
- The codex release tag format `rust-v<version>` is confirmed, as is the asset name
  `codex-<arch>-unknown-linux-musl.tar.gz` and the fact that the archive contains a
  single entry named for the platform, which is what the installer renames to `codex`.
- That binary was downloaded and executed here: `codex-cli 0.148.0`, ELF static-pie,
  `ldd` reports statically linked. So the claim that OpenAI is the only one of the three
  shipping a genuinely self-contained Linux executable is tested, not repeated from a
  vendor page.

Still untested: the npm-based agents install only inside a built image, and no image has
been built.

### Note on testing

Executed here: the rename passes with vendor names masked and verified surviving, the
legacy environment/directory/profile fallbacks, the migration script end to end against a
simulated 1.7.0 layout (credentials confirmed present afterwards), the entrypoint reading
a `gemini`-kind key through the pre-2.0.0 mount point, the deprecation shim, and the full
lint plus inventory gates. **No image was built**; that needs Docker, which is not
available where this was prepared.

## 1.7.0 - 2026-08-19

### Added

- **Python: numpy, pandas and Jinja2** in the baked virtualenv, alongside the existing
  tooling. The build now imports all three and prints their versions, so a wheel that
  installed but cannot load fails the build rather than the first session. Note the size:
  numpy and pandas add roughly 150 MB per image. `--python-tools` still replaces the whole
  set if you want it leaner.

  *Interpretation:* "ninja2" was read as **Jinja2**, the Python templating engine. The
  Ninja *build* tool was already installed in all images as `ninja-build`. If a different
  package was meant, `--python-tools` takes any list.

- **`claude-rocky:10`, a third image**, built on Rocky Linux 10 for work targeting a
  RHEL-family production host. Its compiler handling is deliberately different: RHEL pins
  a conservative system GCC for the life of a release and ships newer compilers as
  Software Collections under `/opt/rh` that normally need `scl enable`. This image probes
  for the newest `gcc-toolset` and `llvm-toolset` that dnf can actually resolve, then puts
  them on `PATH` and `LD_LIBRARY_PATH` through a version-independent `/opt/rh/toolset`
  symlink. So `gcc` is the toolset's GCC with no wrapper, and no version is hardcoded --
  `--build-arg GCC_TOOLSET=15` pins it if you need that. EPEL and CRB are enabled for the
  convenience packages RHEL itself does not carry.

- **Opt-in third-party AI agents**: `scripts/build.sh --agents codex,gemini,grok`.
  Default is none. Of the three vendors, **only OpenAI ships a native Linux executable**
  (a statically linked Rust/musl binary from GitHub Releases, needing no runtime);
  Google's Gemini CLI and xAI's Grok Build are npm packages, so requesting either pulls
  Node into the image. The vendors' `curl … | bash` installers are deliberately not used:
  piping an unpinned remote script into a shell during an image build is the one thing
  this project will not do, and npm at least pins a version and records an integrity hash.
  Claude Code continues to come from Anthropic's signed repository with a fingerprint
  check, which is stronger than any of these.

- **Vendor-aware key profiles.** `kind:` now also accepts `openai`, `gemini` and `grok`,
  mapping to `OPENAI_API_KEY`, `GEMINI_API_KEY` and `GROK_CODE_XAI_API_KEY`; the prefix
  guesser recognises `xai-`, `sk-proj-`/`sk-svcacct-` and `AIza`. The allowlist that
  guards `CLAUDE_BOX_KEY_VAR` was widened to exactly these and no more.

- **`~/.config/claude-box/config`**, an optional persistent settings file. It is *read*,
  never sourced: a config file that could execute code would reach into every future
  container, and this file sits on the credential side of the boundary. Only nine
  `CLAUDE_BOX_*` names are honoured and an environment variable always wins, so a one-off
  override still works.

- **`ALL_IMAGE_KEYS`** in `lib-common.sh`. `build.sh`, `upgrade.sh`, `doctor.sh` and
  `check-updates.sh` iterate over it instead of each hardcoding the image list, so a
  fourth image is one edit.

### Changed

- **`claude-box` now defaults to the Fedora image**, not Ubuntu. Fedora carries the newest
  compilers of the three. Change it per-shell with `CLAUDE_BOX_DEFAULT_IMAGE=ubuntu`, or
  permanently with a line in the config file above.

- **The Ubuntu image's unversioned `gcc`/`g++` now point at the newest GCC installed**
  (16 on 26.04), where they previously pointed at 15. `GCC_DEFAULT=latest` is the new
  default and resolves at build time from `GCC_VERSIONS`, so this does not need editing
  when the list changes; pass a number to pin. Be aware that GCC 16 on 26.04 is a snapshot
  branch, not a released 16.1: "latest" here means newest available, not most conservative.
  Build with `-g 15` to restore the previous behaviour. Every installed GCC is now
  compile-tested during the build, not just the default one.

### Note on testing

Script logic was executed here: config-file precedence and its refusal to execute code,
the `GCC_DEFAULT=latest` resolution including numeric ordering, the Node-conditional
across all eight agent/flag combinations, the Rocky toolset probe against a stubbed dnf,
and the full lint and inventory gates. **No image was built** -- that needs Docker, which
is not available where this was prepared. The Rocky image in particular has never been
compiled and its exact `gcc-toolset`/`llvm-toolset` package names on el10 are probed
rather than verified. Build all three before trusting any of it.

## 1.6.4 - 2026-08-05

Fixes a build failure introduced by 1.6.3. 1.6.3 should not be used.

### Fixed

- **1.6.3's build-time check broke the build it was meant to protect.** It ran the
  entrypoint as the unprivileged user during the build. The entrypoint creates cache
  directories, and the check then tried to remove them; but `/workspace/.ccache-*`
  already existed and was owned by root, so the removal failed and the build stopped:

      rm: cannot remove '/workspace/.ccache-ubuntu/0/a/stats': Permission denied

  Two separate defects were behind that, and both are fixed.

- **The build was leaving root-owned ccache data inside `/workspace`.** `/usr/lib/ccache`
  is first on `PATH` and `CCACHE_DIR` points into `/workspace`, both set by the runtime
  `ENV` block. `toolchain-report.sh` runs after that block, as root, and calls
  `gcc --version` and friends through the ccache shim, which initialises its cache
  directory on any invocation. That is why the leftovers were `stats` files and
  `tmp/.cleaned` rather than compiled objects.

  This predates 1.6.3: 1.6.2 shipped both images with a root-owned
  `/workspace/.ccache-<key>` baked in. It had no effect at run time, because the project
  bind mount hides whatever the image has at `/workspace`, so it only wasted space.
  `toolchain-report.sh` now runs with `CCACHE_DISABLE=1`, and a root step afterwards
  clears `/workspace` and **fails the build if it is not empty** -- it is a mount point,
  and anything in it in the image is by definition invisible and pointless.

- **The unprivileged check is now read-only.** It asserts that the directories the image
  ships are traversable, that `keyfile-lib.sh` sources, that `settings.example.json` is
  readable, and that `/workspace` is empty. It creates nothing, so it cannot fail on
  cleanup. Executing the entrypoint moved to `scripts/smoke-test.sh`, which runs it
  through the image's real `ENTRYPOINT` against a writable workspace and checks that
  `CCACHE_DIR` and `XDG_CACHE_HOME` exist and are writable, that `~/.cache` resolves to
  the same place, and that the directories appear on the host side of the bind mount.
  A failure there costs a test run rather than a build.

- **The entrypoint no longer prints a bare "Permission denied"** when a cache directory
  is not writable. `printf ... 2>/dev/null` does not suppress it, because bash reports a
  failed redirection before the command runs; the redirect is now inside a group with the
  stderr redirection applied to the group. The fallback to `/tmp` always worked, so this
  was noise, but it was noise that looked like a fault.

### Note on testing

The shell logic of both checks was executed here under `setpriv --reuid=65534`, against
a directory at mode 0644 and at 0755, and the entrypoint was run against a root-owned
unwritable cache directory to confirm the message is gone and the exit status stays 0.
Neither image was built: that requires Docker, which was not available where this was
prepared. Building both images is the acceptance test, and it is yours to run.

## 1.6.3 - 2026-08-05

### Fixed

- **Both images failed on the first non-root run**, at the toolchain report that ends
  `build.sh`, with:

      /usr/local/bin/entrypoint.sh: line 7:
      /usr/local/lib/claude-box/keyfile-lib.sh: Permission denied

  The file was present and mode 0644 as intended. The *directory* holding it was also
  mode 0644, and a directory without its execute bit cannot be traversed, so an
  unprivileged process cannot reach anything inside it however readable the file is.

  The cause is BuildKit applying a `COPY`'s `--chmod` to any parent directory it has to
  create (moby/buildkit#5943, a regression from the fix for #4945). `COPY --chmod=0644
  shared/keyfile-lib.sh /usr/local/lib/claude-box/keyfile-lib.sh` therefore created
  `/usr/local/lib/claude-box` with mode 0644. The sibling `COPY` of
  `settings.example.json` also creates a new directory but carries no `--chmod`, so it
  got the default 0755 and worked, which is why exactly one path broke.

  Both destination directories are now created with an explicit
  `install -d -m 0755` before anything is copied into them.

- **The check that would have caught it did not exist, and could not have.** Every
  `RUN` in a Dockerfile executes as root, and root bypasses directory permission checks
  entirely, so the build-time sanity checks passed on a path the actual user could not
  reach. This is a whole class of defect that no root-run check can see.

  Both Dockerfiles now end, after `USER ${USERNAME}`, with a verification block that
  runs as the unprivileged user: it sources `keyfile-lib.sh` exactly as the entrypoint
  does, reads `settings.example.json`, and executes the entrypoint itself. It removes
  the cache directories the entrypoint creates, so the check leaves no residue in the
  image. `scripts/smoke-test.sh` asserts the same thing from outside, against a built
  image, including the directory modes.

  `CLAUDE.md` hard rule 20 states the general form: anything the image ships must be
  verified as the unprivileged user, and `COPY --chmod` must never be the thing that
  creates a directory.

### Note on scope

No image content changes: the same packages, compilers, Python environment and Claude
Code version. Only the mode of two directories and the addition of checks. Rebuild both
images to pick it up.

## 1.6.2 - 2026-08-05

**Breaking: the project mount point is now `/workspace`, not `/work`.** By this
project's own semver rule that is MAJOR, because it breaks any project `CLAUDE.md`
or script that names the old path. It ships as a PATCH release anyway, knowingly and
as a one-off: the package had exactly one user, its author, so there was nothing to
break. The rule is not softened. A change of this shape once there are users is
MAJOR. `docs/roadmap.md` decision D2 records the exception so it reads as an
exception rather than a precedent.

Update anything of yours that names `/work`: project `CLAUDE.md` files, build
scripts, editor configurations, and any `docker run` you wrote by hand.

### Changed

- **`/work` is now `/workspace`**, in both images, the wrapper, the entrypoint's git
  `safe.directory` line, both check scripts, `compose.yaml` and every document.
  `/workspace` is the ecosystem convention: devcontainers use it, Anthropic's
  reference dev container uses it, and several of the projects compared in
  `README.md` use it. `/work` was ours alone.

- **Every cache now lives in the project directory instead of a mount of its own,
  and the default run path drops from three bind mounts to two.** The project
  directory and the Claude Code state directory, and nothing else.

  | Path in your project | Holds |
  |---|---|
  | `.ccache-ubuntu/`, `.ccache-fedora/` | `CCACHE_DIR` |
  | `.cache-ubuntu/`, `.cache-fedora/` | `XDG_CACHE_HOME`, and the target of `~/.cache` |

  `~/.cache` in the image is a symlink into the workspace **and** `XDG_CACHE_HOME`
  is set to the same path. Both, deliberately: the variable covers tools that honour
  XDG but do not use `~/.cache` literally, and the symlink covers tools that expand
  `~/.cache` themselves and ignore XDG, which is common. Setting one and not the
  other leaves a gap.

  Per image, via a `CACHE_KEY` build argument. ccache would be safe to share across
  distros, since it keys on a hash of the compiler binary, but pip is not: a wheel
  built from an sdist carries the tag `linux_x86_64` under both, so one compiled with
  Fedora's toolchain could be reused under Ubuntu's. For an image whose purpose is
  C++ and Python together, that is the failure to design out rather than hope about.

  Four things this would have broken silently, each now handled and each with a
  comment in the code saying why:
  - the `VOLUME` declaration at `~/.cache/ccache` is gone from both Dockerfiles. A
    volume declared at a path resolving through a symlink into a bind mount creates
    an anonymous volume that shadows the real target and discards the cache.
  - `entrypoint.sh` creates the targets before anything can want them, because
    `mkdir -p ~/.cache/pip` through a dangling symlink fails with `File exists`.
  - an unwritable or absent workspace falls back to `/tmp`, which is a tmpfs. That
    covers `scripts/smoke-test.sh` mounting a project read-only, and the documented
    `docker run --rm IMG cat /etc/toolchain-versions`, which mounts nothing.
  - the probe containers in `smoke-test.sh` and `verify-isolation.sh` run with
    `--entrypoint bash` and so never execute any of the above; they set the cache
    variables themselves. Without that, the ccache shim on `PATH` would try to write
    into a read-only mount.

  **The trade being accepted**, so nobody rediscovers it as a bug: a cache per
  project does not share compilations across projects the way one cache per image
  did, and uses more disk in aggregate. `CCACHE_MAXSIZE` drops from 10G, which
  suited one shared cache, to 2G, which a project directory can carry. `README.md`
  documents pointing `CCACHE_DIR` back out of the project for anyone who wants the
  old behaviour.

  `claude-box` warns once if a pre-1.6.2 `$STATE/ccache` is still on disk, with the
  command to remove it, rather than leaving several GB unexplained.

- **`$STATE/claude` is not a cache and did not move.** It holds
  `.credentials.json`. Putting a credential in an agent-writable, git-adjacent
  directory is the specific thing hard rule 1 forbids and `claude-box` already
  refuses for key files.

### Added

- **`docs/claude-isolate-v1.md` section 11a: skills, subagents, MCP servers and
  hooks.** The rest of the document describes what the container can reach and was
  silent on what the agent's own configuration can do inside it. It covers where
  each thing lives and what survives the container, what an MCP server actually adds
  (a stdio server is a subprocess with the container's reach and no more; a
  filesystem server pointed at `/workspace` adds nothing because that is already all
  there is), and the consequence that is not obvious:

  `/workspace/.claude/` is agent-writable, by design. Inside the box that is
  contained. But **the boundary does not follow the directory home**: run Claude Code
  on that same directory on your host afterwards and you inherit whatever the agent
  wrote, and a hook is a shell command. Current versions prompt before running unseen
  hooks, so this is a caution rather than a known exploit, and the mitigation is one
  line of `git diff` over `.claude/`. No skill, subagent or MCP catalogue is shipped:
  they churn, a list implies an endorsement this project cannot back, and a
  network-facing component is a deliberate decision here, not a copy-paste.

- **`docs/roadmap.md`**, moved into the package from a working note that sat outside
  it. A file outside the package is invisible to a session started inside it, which
  defeats the point of writing it down. Section 0 is a decision log: D1 caches in the
  workspace, D2 the `/workspace` rename, D3 the name stays `claude-isolate`.

- **`CLAUDE.md` gains a "Read these before proposing work" table**, because it is the
  only file loaded automatically at the start of a session and everything else has to
  be pointed at from it, plus the instruction to record new decisions in the roadmap
  rather than leaving them in a conversation. Hard rule 19 states the cache layout and
  its four corollaries.

- **Two new smoke-test assertions**: that `~/.cache` really is a symlink into the
  workspace, and that the image's own `CCACHE_DIR` and `XDG_CACHE_HOME` defaults point
  there. The second is read from the image rather than from inside the probe, since
  the probe overrides them.

## 1.6.1 - 2026-08-05

Documentation and one broken link. Nothing about how the package is used changes,
and no image, script behaviour or shipped default is altered.

### Fixed

- **The GitHub links pointed at an account that does not exist.** 1.6.0 shipped
  `github.com/erezstrauss/…` in the two CI badge URLs, the clone command in
  `README.md`, and the security-advisory link in the issue-template config. The
  account is `erez-strauss`. The badges rendered as broken images and the clone
  command failed, which is an unfortunate first impression for a repository whose
  pitch is that you can verify its claims yourself.

### Added

- **`README.md` section "Every file in the package".** One row per file, grouped by
  directory, saying what it is and why it exists rather than restating its name.
  It replaces the ASCII layout tree, deliberately: two lists of the same files is a
  drift risk, and the project's own documentation rule calls drift a defect. There
  is now one authoritative list.

- **`scripts/check-file-inventory.sh`**, which compares that table against the files
  actually present and fails when they disagree. A table nobody updates answers
  "what is this file for?" wrongly, which is worse than not answering it, so this
  makes forgetting a build failure rather than a slow decay. It runs in CI, is in
  the definition of done as item 10, and is on the contributor checklist.

  The two directions are deliberately asymmetric. A file in the tree with no row is
  fatal, since that is the case the check exists for. A row with no file behind it
  is a warning by default and fatal only under `--strict`, because the release
  tarball legitimately omits `.github/` and an extracted tarball would otherwise
  fail on rows that are correct in the repository.

- **`README.md` section "How this compares to other projects"**, replacing the
  flat list of related projects with an actual comparison across the axes that
  differ: which host paths are mounted, what capabilities are held, how the
  credential reaches the agent, what the network policy is, and how deep the
  toolchain goes. Facts are taken from each project's own documentation and were
  checked in August 2026.

  The section states the central trade rather than talking around it: **you can
  have `--cap-drop=ALL` or in-container egress filtering, not both**, because
  filtering outbound traffic from inside the container means running iptables
  inside the container, which needs `NET_ADMIN`. Anthropic's dev container adds
  `NET_ADMIN` and `NET_RAW` and gets a default-deny allowlist; this project drops
  every capability and gets no egress filtering by default. It also says plainly
  where the alternatives are the better choice: breadth of languages, network
  defaults out of the box, parallel agents, and zero setup.

### Changed

- `CLAUDE.md` gains the rule that every file has a row in the inventory, and
  definition-of-done item 10. `CONTRIBUTING.md` and the pull request template
  gained the corresponding check.

## 1.6.0 - 2026-08-04

This release merges two branches that had both grown out of 1.3.2 without knowing
about each other: the 1.4.0/1.4.1 line (security and correctness of the wrapper)
and a separate line that produced its own 1.3.3 and then 1.5.0 (Python, doctor,
repository readiness). There is no 1.5.0 in this history, because the 1.5.0 tree
was not built on 1.4.1 and taking it as the base would have shipped a regression
under a higher version number. **`docs/merge-1.6.0.md` is the record**: which
branch each piece came from, what would have been lost the other way, and the
grounds for every conflict resolution. Read that before this entry if you are
trying to understand why something in this codebase looks like it was added
twice.

The merge rule, stated once: where both branches changed the same thing, the
1.4.x version wins, because its changes were fixes to reproduced defects while
the other branch's were simply the 1.3.2 text it had never had reason to touch.
Where the other branch genuinely added something, it is here.

### Added

- **Python development environment in both images.** A virtualenv at `/opt/venv`,
  first on `PATH` and owned by the unprivileged user, carrying `uv`, `ruff`,
  `mypy`, `pytest`, `pytest-cov`, `ipython`, `build` and `wheel` on top of the
  distro's Python. Both distros enforce PEP 668, so `pip install` into the system
  interpreter is refused; the venv sidesteps that without
  `--break-system-packages`, and a run-time install stays ephemeral so the image
  remains reproducible. `--python-tools "PKGS"` changes the baked set;
  `--uv-python VERSION` additionally bakes in a standalone interpreter. The build
  sanity check verifies the venv tools and asserts the interpreter version.

  Three things changed relative to the branch this came from. The `chown` of the
  venv was `|| true`, which would have hidden the only failure that matters: an
  unwritable `/opt/venv` turns every in-session `pip install` into a permission
  error, which is exactly what the venv exists to prevent. It is fatal now.
  `python3-dev` joined the Ubuntu required set, because a Python environment that
  cannot build a C extension is half an environment. And the venv is now exercised
  by the smoke test rather than only by the build.

- **Podman support**, as a first-class engine rather than a footnote.
  `CLAUDE_BOX_ENGINE=podman` switches every script. This is one variable in
  `lib-common.sh`, not a second binary name written out in twenty places.

  It exists because "alias docker to podman" does not actually work. Rootless
  podman maps the caller to container UID 0 and everything else to a subordinate
  UID, so without `--userns=keep-id` every file the agent writes into `/workspace`
  comes out owned by a UID that is nobody on the host - all the hardening flags
  correct, and the result still wrong. `claude-box` adds `keep-id`, the probe
  containers in `verify-isolation.sh` and `smoke-test.sh` take it from the same
  shared list, and `verify-isolation.sh` asserts its presence under podman because
  no other check would notice its absence. SELinux relabelling (`,z` on bind
  mounts, `relabel=shared` on the credential mount) is applied only when
  `selinuxenabled` reports the host is enforcing, so a Fedora host works and a
  Debian host is unaffected. `doctor.sh` checks for a `/etc/subuid` delegation.

- **GitHub Actions.** `.github/workflows/ci.yml` runs `bash -n`, `shellcheck -x -S
  warning`, hadolint against a `.hadolint.yaml` whose every ignored rule carries
  its justification, the archive invariants, and a grep for credential-shaped
  strings; then builds both images, runs `verify-isolation.sh` and
  `smoke-test.sh` against them, on anything that is not a documentation-only pull
  request, and weekly. The weekly run is the one that matters: distro package
  renames and channel changes are invisible to linting and have broken this
  project before. `.github/workflows/release.yml` fires on a `v*` tag, refuses to
  publish unless the tag, `VERSION` and the `CHANGELOG.md` heading agree, and
  attaches the tarball with `SHA256SUMS` using that version's changelog section as
  the notes.

  Image artifacts are opt-in (`workflow_dispatch` with `upload_images`), because a
  saved image is several GB and uploading one per push would exhaust the
  repository's artifact storage in days. No image is attached to a release at all:
  they are reproducible from the tarball, and shipping a build output as a release
  asset would misrepresent which artifact is the deliverable. Only first-party
  actions are used, and `gh release create` does the publishing; a third-party
  action in the pipeline that builds a security boundary would need a better
  reason than convenience. This is now hard rule 18.

- **`scripts/doctor.sh`** (`claude-box-doctor` after `install.sh`), consolidating
  the host-side checks this project has needed repeatedly: engine reachable; which
  images exist and how they were built; key store and key file modes; which
  profile the current project resolves to; credential-looking files inside a
  project directory; legacy `claude.json` layouts; `.claude.json` validity per
  image. `--fix` repairs the mechanical ones and leaves judgement calls alone.

  Ported onto the single key-file parser: `key_kind_of_file` and `key_var_for_kind`
  do not exist here, `claude_key_kind` and `claude_key_var` do. It gained a check
  that a profile parses to a value at all (a `.key` file with no value line is the
  other route to a mystery 401) and a check that the project directory is not one
  the wrapper refuses. Its `pass`/`fail` helpers were renamed `ok`/`bad`, because
  `pass` is also the password manager behind `-a pass` and a function shadowing it
  is a trap waiting to be sprung. That is now a shell-style rule.

- **`safe_hostname`**, which keeps the image tag visible in the prompt instead of
  truncating at the first dot, and caps the label at 63 bytes because
  `sethostname()` does and Docker surfaces the overflow as "invalid argument".

- **`assert_profile_file_sane`**: a `.claude-profile` containing a credential is
  refused rather than treated as a filename, and the message says to revoke the
  key, because that file is meant to be committed. Called from `claude-box` in the
  parent shell, deliberately not from inside `resolve_key_profile`, which runs in
  a command substitution where `die()` would kill only the subshell. That is now a
  shell-style rule too.

- **`scripts/pack.sh --stage`**, for packing from a git checkout, whose directory
  is named after the repository rather than after the version. Strict remains the
  default. `pack.sh` also asserts the single-top-level-entry invariant against the
  finished archive and deletes it if violated.

- **Python checks in `scripts/smoke-test.sh`**: that `python` resolves to
  `/opt/venv`, that `sys.prefix` agrees, that each tool runs, that site-packages is
  writable without root, and that `pytest` runs a test. Writability is tested by
  touching a file rather than by installing one, so the check does not depend on
  PyPI being reachable.

- **Repository scaffolding for GitHub**: `LICENSE` (MIT), `.gitignore` with
  credential patterns as a backstop, `CONTRIBUTING.md`, `SECURITY.md` stating
  precisely what the sandbox does and does not claim, issue and pull request
  templates that ask for `doctor.sh` output and warn against pasting keys, and
  `dependabot.yml` for Actions only.

- **README sections**: "What the container can see", the full inventory of host
  paths exposed to the container and what is a tmpfs or named volume rather than a
  host directory; "Python"; "Running with Podman"; and "Related projects", which
  names the other ways people run Claude Code in containers, including Anthropic's
  own devcontainer reference and Claude Code's built-in sandbox, with what each
  does differently rather than a bare list.

### Changed

- **`shellcheck -x -S warning` is the gate**, and CI runs that exact command, so a
  warning is a failed build rather than a style note. Two `SC2034` false positives
  in `lib-common.sh` for variables consumed by the scripts that source it are
  suppressed with a stated reason.
- **`verify-isolation.sh` tolerates mount options** when matching a `--volume`
  value. It matched the exact string, which would have started failing on an
  SELinux host for a wrapper doing exactly the right thing. It also now asserts
  that the printed command really is the engine, and, under podman, that
  `--userns=keep-id` is present.
- **`toolchain-report.sh`** records the Python tools alongside the compilers.
- **`docs/api-keys-headless-v1.md`** no longer shows `sk-ant-api03-` followed by
  twenty characters as an example. The credential grep cannot tell that from a real
  key, and one that could would not catch a real one either. The placeholder is an
  angle-bracket stand-in now, and the document says why.
- `install.sh` links `doctor.sh` as well as `smoke-test.sh`.
- Everything taken from the other branch was reflowed to house style: no
  em-dashes.

### Not merged, deliberately

Listed because each looks like an omission and is not. Full reasoning in
`docs/merge-1.6.0.md`.

- The other branch's `CLAUDE.md` hard-rule list, which lacks rules 13 (one
  key-file parser) and 14 (the isolation checks assert against the real command).
  This release takes the 1.4.1 list and adds the genuinely new material to it.
- Its `install.sh` seeding of `~/.config/claude-box/anthropic.env`, which put a
  placeholder that looks like a secret on disk and left `-a envfile` failing
  against `sk-ant-api03-REPLACE-ME` rather than saying the file was never
  configured.
- Its `compose.yaml` note telling the reader to set `CLAUDE_BOX_KEY_VAR` by hand,
  which has been unnecessary since 1.4.0.
- Its Ubuntu package grouping, which had `ripgrep`, `fd-find` and the `libc++` set
  back in the required group where one retired leaf name takes the whole build
  down.
- Its `VOLUME` in JSON form with `/home/dev` hardcoded, which does no variable
  expansion and declares volumes for a user that a `--build-arg USERNAME=…` build
  does not have.

### A note on adding more distributions

The question of a third or fourth Dockerfile (Debian, Alpine, Arch, RHEL/UBI) came
up with this release and the answer is no for now, recorded here so it does not
have to be re-litigated from scratch. Hard rule 10 requires the images to stay
behaviourally equivalent, and each additional image is one more to build,
isolation-check, smoke-test and keep equivalent on every single release; CI time
is roughly linear in the count. Two is a deliberate number: one LTS target and one
fast-moving one, which is the axis that actually changes what a C++ or Python
developer can do. A third image earns its place when it answers a question these
two cannot - a RHEL/UBI image for someone who must match a RHEL production target
is the most plausible candidate, and Alpine is the least, since musl changes
sanitizer and libstdc++ behaviour enough that "behaviourally equivalent" would
stop being true. It is now on the "ask about rather than decide alone" list in
`CLAUDE.md`.

## 1.4.1 - 2026-08-03

Added
- **`examples/`, two C++26 static reflection (P2996) programs**, both compiled, run and
  mutation-tested on Fedora 44 with GCC 16.1.1:
  - `reflect-demo.cpp` reads a type: enum to string with no macro table, a generic struct
    dumper that recurses into nested aggregates, and `static_assert`s over field names
    and counts. Renaming a field fails the build, which is the point.
  - `soa-transform.cpp` writes one: `define_aggregate` synthesises the struct-of-arrays
    form of any aggregate, carrying the field names across, and scatter/gather move data
    between the layouts by walking both member lists in lockstep. Adding a field to the
    source struct changes nothing but the data.
  Reflection is GCC-only today and needs `-freflection`. Fedora's Clang 22.1.8 rejects
  both programs. `examples/` is not COPYed into either image; `.dockerignore` excludes
  it, and the smoke test mounts it at run time like any other project.
- **`scripts/smoke-test.sh`**, which is definition-of-done item 5 as a script rather than
  a list of commands to retype: `claude --version`, `/etc/toolchain-versions`, a C++23
  compile-and-run with every compiler in the image, then the `examples/` programs on any
  compiler that defines `__cpp_impl_reflection`. Compilers without reflection report SKIP
  with a reason, so the Ubuntu image does not fail over a feature its default compiler
  does not have. It runs with the same hardening flags as `claude-box` and mounts
  `examples/` read-only.
- `install.sh` links it as `claude-box-smoke-test`.

Changed
- **`pack.sh` ships an allowlist of package members, not "everything except".** A
  blocklist ships every stray working-tree file nobody thought to name, and two had
  already reached an archive: a machine-local `.claude/settings.local.json` and a session
  note left in the package root. It now names the eleven top-level entries that make up
  the package, fails if one is missing, and logs anything in the tree it is leaving out.
- CLAUDE.md gained an `examples/` row in the layout table, and definition-of-done item 5
  now names the script and states that a reflection check must never be unconditional.

## 1.4.0 - 2026-08-03

Security
- **A `pass`-staged credential was never shredded.** `claude-box` registered a cleanup
  trap and then `exec`ed `docker run`; an `exec`d process replaces the shell, so the EXIT
  trap could not fire and the plaintext key stayed in `/dev/shm` for the rest of the
  host's uptime. The wrapper no longer execs: it runs docker, cleans up, and exits with
  docker's status. `README.md` had been claiming the old behaviour worked.
- **`claude-keys test` no longer puts the credential in the process list.** It passed the
  key as `curl -H "x-api-key: …"`, readable by any local user through `ps` for the life
  of the request. The header now goes in a mode-0600 curl config file on `/dev/shm`.
- **`-a pass` now honours the credential kind.** It always exported
  `ANTHROPIC_API_KEY`, so a `pass` entry holding an OAuth or gateway token was exported
  under a variable that, by Claude Code's own precedence, silently outranked it. The kind
  is detected from the value, or set explicitly with `CLAUDE_BOX_PASS_KIND`.
- **The mount guard covers the directories the README promises are unreachable.** It
  refused `$HOME`, `/`, `/etc`, `/usr`, `/var`, `/opt` but would happily bind-mount
  `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config`, or `~/.claudekeys` itself into the
  container read-write. Those, plus `/root`, `/boot`, `/proc`, `/sys`, `/dev`, `/srv`,
  `/mnt`, `/media` and claude-box's own state directory, are now refused.
- The entrypoint ignores a `CLAUDE_BOX_KEY_VAR` that names anything other than the three
  credential variables, and works the kind out from the key file instead.

Fixed
- **Three key-file parsers that disagreed are now one**, `shared/keyfile-lib.sh`, sourced
  by `lib-common.sh` on the host and COPYed into both images for the entrypoint. Two of
  the disagreements were real failures: a `kind:api` line written without a space after
  the colon was exported to the container *as the credential*, and any secret containing
  `=` was truncated at the first one. Both presented as an unexplained HTTP 401 that
  `claude-keys test` could not reproduce, because it used a different parser.
- **`upgrade.sh` could not upgrade anything without `-c`.** The agent install is a Docker
  layer; nothing in the build invalidated it except the daily OS-update stamp. So
  `upgrade.sh --no-updates` installed nothing, and a second upgrade on the same day did
  nothing either, both reporting "channel had nothing newer". It now resolves what the
  channel offers and passes it as `CLAUDE_VERSION`, which is what busts that layer, and
  falls back to `--no-cache` if the channel cannot be queried.
- **`upgrade.sh -k/--keep-cache` was a no-op**, because `build.sh` adds `--pull` whenever
  OS updates are on, which they were. It now implies `--no-updates` and warns that it
  does, since OS layers can only be reused when nothing before them changes.
- **`claude-box` no longer walks the whole state directory on every launch.** It ran
  `chmod -R go-rwx` over a ccache that is allowed to reach 10 GB, costing seconds per
  start; it now chmods the directories it creates.
- `claude-box -k ./relative/path.key` works; the path is resolved before it reaches
  `--mount`, which requires an absolute source and previously failed with docker's error
  rather than ours.
- `claude-keys path` prints a trailing newline.
- A hostname built from an image key that truncated onto a hyphen was not RFC-1123 valid,
  the same class of bug 1.3.2 fixed for colons.
- `VOLUME` in both Dockerfiles was JSON-form with `/home/dev` hardcoded, which does no
  variable expansion, so `--build-arg USERNAME=…` declared volumes for a user that did
  not exist. Now shell-form with `${USERNAME}`.

Added
- **`claude-box -n`**, a dry run that prints the exact `docker run` argv one word per
  line and exits.
- **`scripts/verify-isolation.sh` asserts against that argv.** It used to rebuild the
  hardening flags itself, so the wrapper could have dropped `--cap-drop=ALL`,
  `no-new-privileges` and `--user` and every check would still have printed PASS. It now
  checks the real command, that every bind source is the project or the state directory,
  and that no forbidden host path appears anywhere in it. New in-container checks: the
  effective capability set is empty, `no_new_privs` is set, `/usr/local/bin` is not
  writable. New third phase: `--network none` really does block name resolution.
- `CLAUDE_BOX_PASS_KIND`.

Changed
- **Package groups now match the rule they were written for.** `ripgrep`, `fd-find` and
  the `libc++` set were in the Ubuntu image's *required* group while the same packages
  were optional on Fedora, so one retired leaf name could take the whole Ubuntu build
  down. They are optional in both images now.
- **The two images ship the same tools again.** Ubuntu gained `autoconf`, `automake`,
  `libtool`, `patch`, `diffutils`, `bzip2` and `iputils-ping`; Fedora gained `time` and
  `nano`. `perf` remains Fedora-only, and the Ubuntu Dockerfile now says why:
  `linux-tools-common` does not carry the kernel-matched binary.
- `check-updates.sh` and `upgrade.sh` share one channel-query function in
  `lib-common.sh`; `claude-keys` uses the shared profile resolution instead of its own
  copy. The throwaway query containers gained `no-new-privileges` and a pids limit, and
  keep their capabilities on purpose: apt needs `CAP_SETUID` to drop to `_apt` when it
  fetches.
- `install.sh` no longer seeds `~/.config/claude-box/anthropic.env` from the example. It
  put a placeholder that looks like a secret on disk and left `-a envfile` failing
  against `sk-ant-api03-REPLACE-ME` rather than saying it was never configured.
- `claude-keys` refuses to guess at a confirmation prompt when there is no terminal,
  rather than failing on `/dev/tty`; its `--help` no longer comes from `sed`-ing its own
  header, which truncated silently whenever a comment was added.
- `pack.sh` excludes `.claude/settings.local.json`. It is the packager's machine-local
  Claude Code settings, with local paths and permission allowlists in it, and it was
  being shipped inside the release archive.
- Documentation: house style forbids em-dashes, so the prose no longer uses them.
- `CHANGELOG.md`: the 1.3.1 and 1.3.2 entries were dated a day into the future.

## 1.3.2 - 2026-08-03

Fixed
- **`.claude.json` was corrupted on startup** with `JSON Parse error: Unexpected EOF`.
  Two compounding causes, both mine:
  - the wrapper created the host file with `touch`, i.e. **empty**, and an empty file is
    not valid JSON;
  - it bind-mounted that single *file* into the container. A single-file mount pins the
    inode, so a writer that replaces the file with `rename()` - the normal way to write
    a config atomically - fails, and a writer that truncates and rewrites in place leaves
    a partial file if interrupted.
  The wrapper now sets `CLAUDE_CONFIG_DIR=/home/dev/.claude`, so `.claude.json` lives
  inside the directory that was already mounted, where rename works. No single-file
  mount remains for any writable path.
- `claude-box` validates the config before each run and, if it is empty or truncated,
  moves it to `<state>/claude/backups/` and starts fresh - instead of leaving you at the
  "Reset with default configuration" prompt on every start. Valid configs are untouched.
- Existing `<state>/claude.json` files are migrated into the config directory on the next
  run if they parse, and discarded if they do not.
- **Container hostname is now RFC-1123 safe.** It was built from the image key, so
  `-i claude-fedora:44-cc2.1.211` produced `claude-box-claude-fedora:44-cc2` - a colon in
  a hostname, which some Docker versions reject outright.

Added
- `json_ok` in `lib-common.sh`: validates JSON with `python3`, then `jq`, then a
  conservative heuristic, so the repair path does not assume either tool is installed.
- CLAUDE.md rule: never bind-mount a single file for anything the container writes.

## 1.3.1 - 2026-08-03

Fixed
- **The Fedora image failed to build.** Two package names in the install list were wrong
  for Fedora 44: `benchmark-devel` does not exist (the package is
  `google-benchmark-devel`) and `catch-devel` was Catch 1.x, superseded by
  `catch2-devel`. dnf5 aborts the whole transaction on an unresolvable argument, so one
  bad name took the entire image down. The `Package ... is already installed` lines in
  that error are informational, not the cause.
- `ln -sf` for the `fd`/`fdfind` alias no longer assumes the package installed.

Changed
- **Package lists are now split into required and optional.** Compilers, build tools and
  core utilities are required and still fail the build loudly. Convenience libraries
  (boost, fmt, catch2, gtest, gmock, google-benchmark, perf, ripgrep, fd) are installed
  with `--skip-unavailable` on dnf, or one at a time on apt, so a renamed or retired leaf
  package logs a note instead of breaking the image. A compiler must never be moved into
  the optional group to make a build pass.
- Both Dockerfiles now end their install phase by verifying the toolchain: every critical
  binary is on `PATH`, and a C++23 translation unit compiles with each compiler
  (`g++`, `clang++`, and `g++-${GCC_DEFAULT}` on Ubuntu). A build that would have
  produced a subtly broken image now fails at build time instead.
- `build.sh` warns when `-g/--gcc`, `-L` or `-l` are passed with the `fedora` target;
  those flags apply to the Ubuntu image only and were previously ignored in silence.

## 1.3.0 - 2026-08-03

Added
- **`~/.claudekeys` credential store and the `claude-keys` command.** Browser-free
  authentication: `init`, `add`, `list`, `which`, `link`, `path`, `rm`, `check`, `test`.
  Keys are read from the terminal with echo off, stored one profile per file at mode
  0600, and bind-mounted read-only into the container at `/run/secrets/claude-key`. A
  mounted file stays out of `docker inspect` and the host process list; `-e`/`--env`
  does not. `list` and `add` print fingerprints, never keys.
- **Per-project key selection** without putting a secret in the project: a
  `.claude-profile` file naming a profile (safe to commit), `claude-keys link`, a profile
  named after the directory, then `default`.
- **`claude-box -k PROFILE|PATH`** and a new default auth mode `auto`, which uses the
  store when a profile resolves and otherwise falls back to browser login. `-a login` is
  the explicit browser flow; `oauth` is kept as an alias.
- **Credential-kind awareness.** A profile's `kind:` selects the variable to export - `api` → `ANTHROPIC_API_KEY`, `oauth` → `CLAUDE_CODE_OAUTH_TOKEN`, `bearer` →
  `ANTHROPIC_AUTH_TOKEN` - because Claude Code's precedence means the wrong variable
  silently outranks the right credential. Optional `<profile>.env` carries non-secret
  routing settings (`ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`).
- **`docs/api-keys-headless-v1.md`**: which credentials skip a browser and which do not,
  the store format, per-project keys, `claude setup-token` for subscription users,
  `apiKeyHelper` for rotating credentials, CI usage, and a troubleshooting table.
- **OS update control.** `OS_UPDATES` (default 1), `OS_TAG`, and `UPDATE_STAMP` build
  args in both Dockerfiles, exposed as `build.sh --no-updates` and `-t/--os-tag`.
  Builds now apply every pending distro update and pull a fresh base image by default;
  `--no-updates` takes packages exactly as the base tag shipped them, for a reproducible
  rebuild. `UPDATE_STAMP` carries the build date so Docker cannot reuse a stale upgrade
  layer and quietly turn the default into a no-op.
- Image labels `com.claude-box.os-updates`, `.os-tag`, `.update-stamp`,
  `.package-version`, so `docker inspect` answers how an image was built.
- `upgrade.sh` gained `--no-updates` and `-t/--os-tag`; by default an upgrade now
  refreshes OS packages as well as the agent.
- The container banner reports which credential is active.

Changed
- `build.sh` and `upgrade.sh` parse long options; `--no-updates` needs one.
- `install.sh` links `claude-keys` and creates the key store.
- `shared/anthropic.env.example` is marked legacy in favour of the key store.
- `docs/claude-isolate-v1.md` §4 now summarises credentials and points at the new
  document rather than duplicating it.

Security
- `claude-box` **refuses a key file located inside the mounted project directory** and
  explains why: that directory is writable by the agent and everything it spawns, and is
  one `git add .` from a public repository.

Fixed
- The entrypoint's key parser treated the `kind:` metadata line as the key value when a
  profile file carried metadata. It now skips comments and `header:`-style lines, trims
  whitespace, and tolerates both bare values and `NAME=value`.

## 1.2.0 - 2026-07-30

Changed
- **Ubuntu image is now Ubuntu 26.04 LTS ("Resolute Raccoon")**, released 2026-04-23,
  built as `claude-ubuntu:26.04`. It ships GCC 15.2 as the system compiler, GCC 16
  alongside it, glibc 2.43, binutils 2.46 and Python 3.14.
- **Clang now comes from the Ubuntu archive (21), not apt.llvm.org.** 24.04 only carried
  Clang 18, which is why the previous image added a third-party repository; 26.04 makes
  that unnecessary. One fewer signing key to trust, one fewer step that broke whenever
  upstream lagged a new Ubuntu codename. The unversioned `clang`, `clang-tidy`,
  `lld`, `libc++-dev` metapackages are used, so nothing needs editing when Ubuntu moves.
- `LLVM_FROM_UPSTREAM=1` (`scripts/build.sh -L`) keeps the apt.llvm.org path available
  for an LLVM newer than the archive's; `LLVM_VERSION` now defaults to 22 and only
  applies on that path.
- `BASE_IMAGE` is a build arg, so a future LTS needs no Dockerfile edit to try.

Added
- `GCC_VERSIONS` (default `15 16`) and `GCC_DEFAULT` (default `15`) build args, exposed
  as `scripts/build.sh -g`. GCC 16 is installed either way and reachable as `g++-16`;
  it is a snapshot branch on 26.04, so it is deliberately not the default.
- `/etc/toolchain-versions` now lists the versioned GCCs it finds, not just `gcc`/`g++`.
- Documented how to carry an OAuth login across an image-tag change, in
  `docs/upgrading-claude-code-v1.md`.

Migration
- The image tag changed from `claude-ubuntu:24.04` to `claude-ubuntu:26.04`, so the
  per-image state directory changed too. Copy the login across (ccache should start
  cold, since the compiler changed):

      OLD=~/.local/share/claude-box/claude-ubuntu_24.04
      NEW=~/.local/share/claude-box/claude-ubuntu_26.04
      mkdir -p "$NEW" && cp -a "$OLD/claude" "$OLD/claude.json" "$NEW/"

- Build trees produced by the old image's Clang 21-from-upstream and the new archive
  Clang 21 should not share a directory; use `build/<image>-<compiler>/`.

## 1.1.0 - 2026-07-30

Added
- Packaged layout: `shared/`, `scripts/`, `docs/`, `docker-ubuntu/`, `docker-fedora/`.
- `scripts/claude-box` wrapper, previously an inline listing in the documentation.
- `scripts/check-updates.sh`: read-only comparison of the Claude Code version baked
  into each image against the candidate offered by the signed apt/dnf channel, plus
  the upstream release for reference.
- `scripts/upgrade.sh`: rebuild with a newer or pinned agent, automatic `:…-prev`
  rollback tag, before/after version report.
- `scripts/build.sh`, `scripts/install.sh`, `scripts/verify-isolation.sh`,
  `scripts/pack.sh`, `scripts/lib-common.sh`.
- `shared/entrypoint.sh` and `shared/toolchain-report.sh`, now `COPY`ed into both
  images instead of being duplicated as heredocs in each Dockerfile.
- `/etc/toolchain-versions` in both images, stamped with the package version.
- `-u` self-update mode in `claude-box` for people who prefer in-container
  `claude update` over image rebuilds.
- Optional `claude-toolchains` volume auto-mounted at `/opt/toolchains` when present.
- `docs/upgrading-claude-code-v1.md`, `README.md`, `CLAUDE.md`, this changelog.
- `shared/compose.yaml`, `shared/tinyproxy.conf.example`, `shared/settings.example.json`,
  `shared/anthropic.env.example`.

Changed
- Docker build context is now the package root, since both Dockerfiles `COPY shared/`.
- Both Dockerfiles accept `PACKAGE_VERSION` for provenance.

Fixed
- Several `[[ … ]] && cmd` statements that would abort under `set -e` when the test
  was false (image selection in `build.sh`, optional run flags in `claude-box`,
  version pinning in `upgrade.sh`, archive overwrite check in `pack.sh`).

## 1.0.0 - 2026-07-30

- Initial `Dockerfile.claude-ubuntu` (Ubuntu 24.04, Clang/LLVM 21, GCC 14),
  `Dockerfile.claude-fedora44` (Fedora 44), and `docs/claude-isolate-v1.md`.
- Claude Code installed from Anthropic's signed apt/dnf repositories with a fatal
  GPG fingerprint check; auto-updater disabled; unprivileged user with host-matched
  UID/GID; no secrets in any layer.
