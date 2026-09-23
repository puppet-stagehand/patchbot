# Changelog

## [0.2.0] - 2026-09-23

- **Breaking (external fact consumers):** `facts.d/patchbot.sh`'s apt, dnf, and yum
  branches no longer emit the `patches[]` array (`{"id","severity","security"}`).
  All three now emit `packages[]` (`{"name","arch","current","available","repo",
  "security"}`), carrying real installed/available version and repo/suite data
  instead of a bare identifier + approximated severity. Any external consumer of
  the retired `patches[]` shape (PuppetDB queries, third-party reporting) must
  move to `packages[]`. Puppet Stagehand Console's own read side
  (`patchFactPackages`) already accepts both shapes, preferring `packages[]` and
  falling back to `patches[]` for nodes still running a pre-0.2.0 module — see
  puppet-console phase 999.47 (`packages-tab-version-and-installation-source`).
- dnf/yum's installed (`current`) version now comes from one batched `rpm -q`
  lookup per fact run (`rpm_installed_versions`/`rpm_installed_version_for`),
  not `check-update`'s candidate-version column, and not one `rpm -q` per
  pending package.
- Package names are validated (`pkgname_is_safe`) against the same
  `[A-Za-z0-9][A-Za-z0-9._:+-]*` token shape `tasks/patch.sh`'s `patch_ids`
  validation already enforces, before reaching `rpm`'s argv.
- Severity is no longer tracked as a separate field; only the `security`
  boolean survives.
- The Windows fact (`facts.d/patchbot.ps1`) is unaffected — it keeps its own
  legacy `patches[]`-shaped KB-entry array.

## [0.1.0] - 2026-08-20

- refactor: rename pcm module to stagehand (puppetlabs-stagehand) (2a33ade)
- feat: extract trivy/openscap/patchbot; patchbot Package Updates + Windows Update (b367ddd)
- fix(patchbot): argument injection via patch_ids in patch.sh (b0e3606)
- test(02-01): add failing test for patch.sh JSON-on-fail and sensitive-param contract (f045495)
- feat(02-01): patch.sh embeds JSON on business-logic failure, patch.json marks ingest_token sensitive and input_method both (2e49529)
- test(02-01): add Pester coverage for patch.ps1 (RED, unexecuted — no local pwsh) (b441acd)
- feat(02-01): patch.ps1 emits FailJson on business-logic failure (unexecuted locally — verified on Windows/pwsh host via Task 3's checkpoint) (e1dd5cf)
- fix(patchbot,trivy,openscap,inspector): correct metadata.json/README to unified stagehand Forge author + puppet-stagehand org (SPLIT-01, D-16/D-17/D-18, supersedes D-02) (e592c49)
