# Changelog

## [0.1.0] - 2026-08-20

- refactor: rename pcm module to stagehand (puppetlabs-stagehand) (2a33ade)
- feat: extract trivy/openscap/patchbot; patchbot Package Updates + Windows Update (b367ddd)
- fix(patchbot): argument injection via patch_ids in patch.sh (b0e3606)
- test(02-01): add failing test for patch.sh JSON-on-fail and sensitive-param contract (f045495)
- feat(02-01): patch.sh embeds JSON on business-logic failure, patch.json marks ingest_token sensitive and input_method both (2e49529)
- test(02-01): add Pester coverage for patch.ps1 (RED, unexecuted — no local pwsh) (b441acd)
- feat(02-01): patch.ps1 emits FailJson on business-logic failure (unexecuted locally — verified on Windows/pwsh host via Task 3's checkpoint) (e1dd5cf)
- fix(patchbot,trivy,openscap,inspector): correct metadata.json/README to unified stagehand Forge author + puppet-stagehand org (SPLIT-01, D-16/D-17/D-18, supersedes D-02) (e592c49)
