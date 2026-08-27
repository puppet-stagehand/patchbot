# Release process

This module is vendored by `puppet-installer` and `puppet-console` via
`vendor.yaml`'s TOFU (trust-on-first-use) checksum pinning: `hack/vendor-modules.sh`
fetches this repo at a tagged ref and records a `tree_sha256` in `MANIFEST.json`, so a
future re-vendor at the same ref is guaranteed byte-identical to what was trusted before.

TOFU pinning proves *integrity* — "these are the same bytes I trusted last time." It
proves nothing about whether those bytes were safe to trust in the first place. That's
what the CI gates below are for.

## What runs, and when

| Workflow | Trigger | What it checks | Blocks |
|---|---|---|---|
| `.github/workflows/ci.yml` | Every PR touching module content, every push to `main` | `pdk`-equivalent validate/lint, rspec-puppet across the Puppet/OpenVox version matrix, Bolt task shell tests (POSIX), Bolt task Pester tests (Windows), the security scan (below) | The PR merge |
| `.github/workflows/security-scan.yml` | Called by `ci.yml` (every PR) and `release.yml` (every tag) | ClamAV signature scan, gitleaks (working tree + full history), `tools/supplychain/scan.sh` (Puppet/Ruby/PowerShell pattern checks) | Whichever workflow called it |
| `.github/workflows/release.yml` | Push of a `v*` tag | The security scan again, against the exact tagged tree, then publishes a GitHub Release | The GitHub Release |

**On the release gate specifically:** GitHub has no server-side hook that can reject a
`git push --tags` outright — a tag, once pushed, exists whether or not anything downstream
approves of it. What `release.yml` actually gates is the **GitHub Release**: if the scan
fails, no release gets published, and the workflow run is a loud red X against that tag.
**A `v*` tag with no corresponding GitHub Release did not pass the gate — treat it as
failed, not as a forgotten manual step**, and do not point `vendor.yaml` at it.

## The version matrix

`ci.yml`'s `unit-test` job runs rspec-puppet against:

- **Puppet Core 7** and **Puppet Core 8** — real, currently-shipping releases. These block
  the PR.
- **OpenVox 8** — real, currently-shipping (OpenVox is a drop-in for Puppet's own `Puppet::`
  Ruby namespace and `puppet` binary name; this is a pure Gemfile gem-name/version swap, no
  test code branches on which one loaded). Blocks the PR.
- **Puppet Core 9** and **OpenVox 9** — wired in as `experimental: true` (non-blocking).
  Neither exists as a stable release yet as of this doc's last update (2026-08-21: latest
  published `puppet` gem is 8.10.0; `openvox` is at 9.0.0-beta2). These legs will simply
  keep failing to resolve until each ships for real — that's expected, not a bug — and they
  will start passing automatically the moment a stable release lands, with no workflow edit
  required.

This is a **compatibility signal**, not a change to what this module officially supports:
`metadata.json`'s `requirements.puppet` stays `>= 8.0.0 < 9.0.0` (this project's
established, deliberate scope). If the 7/OpenVox legs go red, that's real information worth
looking at even though nothing here commits to shipping Puppet-7-compatible code.

`ci.yml` also runs a `windows-task-tests` job (Pester, on `windows-latest`) for
`tasks/patch.Tests.ps1` — this module, unlike `stagehand`, ships a real Windows Bolt task
(`tasks/patch.ps1`) and Windows external fact (`facts.d/patchbot.ps1`), so this leg has no
equivalent in `stagehand`'s pipeline. It blocks the PR like any other `needs: lint` job;
it is the first time `patch.Tests.ps1`'s assertions run against a real `pwsh`/Pester
runtime rather than being authored blind (no local `pwsh` on the authoring machine).

## When the security scan finds something real

Fix it. That's almost always the right answer — a real malware signature, secret, or the
static-pattern checks below are not things you route around.

### If it's a genuine false positive

Never disable a check wholesale. Use a scoped, dated, owned exception instead, and expect
to revisit it:

- **`tools/supplychain/scan.sh` (Puppet/Ruby/PowerShell pattern checks):** add an entry to
  `supplychain.waivers.json` — `rule`, optional `path` glob, optional `contains` substring
  to scope it to one exact finding, plus required `reason`/`owner`/`expires`
  (`YYYY-MM-DD`). An expired waiver stops suppressing the finding automatically — the scan
  reports `WAIVER EXPIRED` and fails the build again, so a stale exception can't quietly
  live forever.
- **gitleaks:** add a scoped `[[allowlist]]` entry to `.gitleaks.toml` (`paths`/`regexes`,
  never a blanket rule disable), preceded by a `# WAIVER: owner=... reason=... expires=...`
  comment — gitleaks itself doesn't enforce expiry, so this is a review convention, not a
  tooling one. Check the file periodically for anything past its stated date.
- **ClamAV:** essentially never waive a real hit. If it's a demonstrated false positive
  (e.g. a security-tool test fixture that trips a heuristic signature), exclude that exact
  path in the workflow's `clamscan` invocation with an inline dated comment explaining why
  — same spirit as the other two, just no separate file for a single tool flag.

### Rule reference (`tools/supplychain/scan.sh`)

Modeled on `puppet-console`'s Go supply-chain gate (`tools/supplychain`,
`docs/SUPPLY-CHAIN.md`'s "no install-time execution" control) — same philosophy (rule ID +
threat + remedy, dated/scoped/owned waivers that expire), applied to Puppet DSL/Ruby/
PowerShell instead of Go. Not the same tool or code.

| Rule | What it catches |
|---|---|
| `PSC-INST-001` | An `exec`/task command that pipes a downloaded script straight into a shell (`curl \| sh` and friends) — unpinned, unreviewed, a different payload every time it runs. |
| `PSC-INST-002` | A base64-looking blob (44+ chars) in a manifest/template/task/fact/lib file with no comment nearby explaining what it is. Filesystem paths and hex digests (git SHAs, sha256s) are excluded — both are subsets of the base64 alphabet but aren't base64 payloads. |
| `PSC-INST-003` | `eval`/`instance_eval`/`class_eval`/`module_eval`/`Marshal.load`, or `send`/`public_send` with a non-literal (computed) method name, in this module's Ruby (custom types/providers/functions/facts). Code built and executed at runtime can't be read at review time. |
| `PSC-INST-004` | `Invoke-Expression`/`IEX`, or `-EncodedCommand` (and its unambiguous abbreviations, e.g. `-enc`), in this module's PowerShell (`tasks/patch.ps1`, `facts.d/patchbot.ps1`). The PowerShell-side equivalent of `PSC-INST-003` — dynamic code execution and a payload deliberately hidden from the command line/process listing. New in `patchbot`: `stagehand`'s reference scan.sh has no PowerShell content to check. |

Run it locally any time with `sh tools/supplychain/scan.sh`; test the checker itself with
`sh tools/supplychain/scan_test.sh`.

## Cutting a release

1. Bump `metadata.json`'s `version`, add a `CHANGELOG.md` entry.
2. Merge to `main` — `ci.yml` (including the security scan) must be green.
3. `git tag -a vX.Y.Z -m '...' && git push origin vX.Y.Z`.
4. Watch `release.yml`: the security scan runs one more time against the tagged tree, then
   the GitHub Release publishes automatically if it passes.
5. Bump the pin in `puppet-installer`'s and/or `puppet-console`'s `vendor.yaml` and re-run
   `hack/vendor-modules.sh` there to pick it up.
