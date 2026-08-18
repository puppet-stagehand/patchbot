# patchbot — Package Updates + Windows Update for the Puppet Stagehand Console

Forge: `souldonetworks-patchbot`. Split out of the `stagehand` module so patch
tooling versions and ships independently. Two complementary paths, both
cross-platform (Linux and Windows):

- **Pull path** — `include patchbot` classifies a node with the `patchbot`
  external fact. On every agent run, patch posture — summary counts *and* an
  itemized list of available patches — reaches the console via PuppetDB, with
  no Bolt push required. On Linux, `patchbot` also keeps the package
  manager's own update metadata fresh (a small systemd timer) so the fact's
  counts stay meaningful between runs; on Windows this is a deliberate no-op
  (Windows Update maintains its own metadata, and the fact queries WUA live
  every run). The fact scripts ship in `facts.d/` and reach agents by
  pluginsync automatically once the module is in the environment modulepath.
- **Push path** — the `patchbot::patch` Bolt task (the console's "Patch"
  button) applies updates on demand — all, security-only, or a specific
  hand-picked set — and best-effort refreshes the fact's cache immediately
  afterward, rather than waiting for the next agent run.

Same "bring your own" posture as `trivy`/`openscap`: the console only cares
that *something* keeps the `patchbot` fact populated in the shape below — use
your own patch-posture reporter if you'd rather, and skip this module.

## Two console screens, one fact shape

- **Package Update** screen (Linux) — the coarse-grained experience: apply
  all available updates, or security-only, across a node group.
- **Windows Update** screen — modeled on double-clicking Windows Update on a
  server: see the individual available updates by KB and either apply all or
  hand-pick specific ones.

The console decides which screen a node belongs on using `$facts['kernel']`
(`'Linux'` vs `'windows'`) — **not** a different fact structure. `patchbot`
reports the exact same JSON keys on both platforms; only the values differ
(`id` is a KB number on Windows, a package name on Linux).

## Class

`include patchbot`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `manage_cache` | `Boolean` | `true` | Keep package-manager update metadata fresh via a systemd timer. **Linux only** — a no-op on Windows nodes (see above). |
| `cache_refresh` | `String[1]` | `'daily'` | systemd `OnCalendar` expression for the refresh timer. |

## Task

`patchbot::patch` — dispatches to `tasks/patch.sh` (POSIX) or
`tasks/patch.ps1` (Windows) automatically via Bolt's `implementations`
metadata; same parameters and same JSON output shape either way.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `console_url` | `Optional[String[1]]` | — | Server-injected; unused by the patch itself (posture reaches the console via the fact, not the task's own output). |
| `ingest_token` | `Optional[String[1]]` | — | Server-injected; unused by the patch itself. |
| `security_only` | `Boolean` | `false` | Apply only security updates when true; otherwise apply all available updates. Ignored when `patch_ids` is set. |
| `patch_ids` | `Optional[Array[String[1]]]` | — | Install only these specific ids, as reported in the fact's `patches[]` array (KB numbers on Windows, package names on Linux). Takes priority over `security_only`. |
| `reboot` | `Boolean` | `false` | Reboot the node afterward if a reboot is required. |

On Linux, `patch_ids` requires `jq` on the target (only when actually used —
every other path stays dependency-light). On Windows, no extra dependency:
`ConvertFrom-Json` is built in.

## The `patchbot` fact schema

```json
{
  "patchbot": {
    "available": 4,
    "security": 1,
    "reboot_required": false,
    "last_checked": "2026-08-18T14:03:00Z",
    "patches": [
      { "id": "KB5031354", "severity": "high", "security": true },
      { "id": "openssl", "severity": "high", "security": true },
      { "id": "some-lib.x86_64", "severity": "unknown", "security": false }
    ]
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `available` | integer | Count of packages/updates with an available update. |
| `security` | integer | Subset of `available` that are security updates. |
| `reboot_required` | boolean | Whether a pending reboot has been flagged (`/var/run/reboot-required` or `needs-restarting -r` on Linux; the WUA `SystemInfo.RebootRequired` property on Windows). |
| `last_checked` | string | ISO 8601 UTC timestamp of the last time this fact ran. |
| `patches[].id` | string | The identifier this entry round-trips into the task's `patch_ids` parameter. KB number (`KB5031354`) on Windows; bare package name (or `name.arch` on RHEL-family) on Linux. |
| `patches[].severity` | enum | `low` \| `medium` \| `high` \| `unknown` — the same severity scale `compliance.v1` uses. On Windows this is MSRC's rating (Critical/Important collapse to `high`, Moderate → `medium`, Low → `low`). On Linux it's an approximation: `high` if the package manager's security channel flags the update, `unknown` otherwise — Linux package managers don't expose per-package severity as cleanly as WUA does. |
| `patches[].security` | boolean | Whether this update is classified as a security update. |

**Deliberately no `title` field** — the fact is stored in PuppetDB and
re-sent every agent run, and `patches[]` can run to dozens of entries on a
stale node. The console resolves human-readable display text from `id`
itself rather than paying that cost in every fact upload.

Structured JSON output requires Facter 4, which ships with Puppet 8 —
OpenVox, Puppet Core, and PE all qualify.

## Files

- `manifests/init.pp` — the `patchbot` class (Linux refresh timer only; the
  fact itself needs no Puppet-side management beyond pluginsync).
- `facts.d/patchbot.sh` — the Linux/POSIX fact (apt/dnf/yum).
- `facts.d/patchbot.ps1` — the Windows fact (WUA COM API). Coexists with
  `patchbot.sh` in the same directory; Facter only ever runs the one that
  matches the platform.
- `tasks/patch.json` — task metadata, including the `implementations` split.
- `tasks/patch.sh` / `tasks/patch.ps1` — the two task implementations.
