# Security

ai-box is a sandbox, so a defect in it can mean the sandbox does not hold.
Please read the threat model in `docs/operating-guide.md` section 1 before reporting:
several things that look like weaknesses are documented, deliberate limits.

## What this project claims

In the default configuration, an agent running in the container cannot read or write any
host path other than the mounted project directory and ai-box's own per-image state
directory, cannot reach the Docker socket, cannot gain privileges, and cannot persist
anything outside those paths.

`scripts/verify-isolation.sh` is the executable form of that claim. It asserts against
the argv that `ai-box -n` prints, not against its own copy of the flags, so a
regression in the wrapper fails the check rather than passing it.

## What it explicitly does not claim

- **Container escape via a kernel bug.** Docker shares the host kernel. If that is in
  your threat model, use rootless Docker, gVisor (`--runtime=runsc`), or a VM-backed
  runtime. See `docs/operating-guide.md` section 10.
- **Network exfiltration.** Outbound access is unrestricted unless you configure the
  egress allowlist in section 8.
- **Protection of the mounted project.** That directory is fully writable by design.
  Keep it in git and push often.
- **`docker` group membership.** On a rootful daemon this is equivalent to host root.
  That is a property of Docker, not of this project, and it is one reason the Podman
  instructions in `README.md` exist.

## Reporting

Report suspected vulnerabilities privately through GitHub's **Report a vulnerability**
button under the Security tab, not as a public issue. Useful reports include the package
version (`cat VERSION`), the output of `scripts/doctor.sh`, and the smallest sequence of
commands that demonstrates the problem. Never paste a credential into a report; a
fingerprint from `ai-keys list` is enough.

Reports worth making include: a host path readable or writable from the container that is
not in the mount inventory in `README.md`; a way to make `ai-box` mount something it
should refuse; a credential appearing in an image layer, a build argument,
`docker history`, or `docker inspect`; or a privilege escalation inside the container.
