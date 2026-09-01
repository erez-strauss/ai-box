## What this changes

<!-- One paragraph. Why, not just what. -->

## Checks

- [ ] `shellcheck -x -S warning` clean
- [ ] `tests/run.sh` passes
- [ ] `scripts/check-image-parity.sh`, `check-doc-links.sh`, `check-file-inventory.sh` pass
- [ ] `VERSION` bumped and `CHANGELOG.md` updated
- [ ] Images build from a cold cache, if a Dockerfile changed
- [ ] `verify-isolation.sh` and `smoke-test.sh` pass for every image, if behaviour changed

## Isolation

- [ ] No new mount, capability or network path in the default run
- [ ] No credential can reach an image layer, a build argument or `docker inspect`

<!-- If any box above is unchecked, say why here. An honest exception is fine;
     a silently skipped check is not. -->
