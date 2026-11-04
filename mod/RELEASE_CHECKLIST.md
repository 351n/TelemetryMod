# Telemetry Mod release checklist

Use this list for each public Telemetry Mod release.

## Prepare

- [ ] Update `telemetry-mod/info.json`: version, Factorio target, dependency floor, description, homepage, and contact.
- [ ] Add the version to `telemetry-mod/changelog.txt` in Factorio changelog format.
- [ ] Keep all user-facing strings in both `locale/en/telemetry.cfg` and `locale/pl/telemetry.cfg`.
- [ ] Update `telemetry-mod/README.md` and the copy in `MOD_PORTAL.md` when behavior or configuration changes.
- [ ] Do not include relay or bot changes unless that component has its own separately scoped release.

## Verify

- [ ] Install the example dependencies with `npm ci --prefix examples`, then run `pwsh -File scripts/test_factorio.ps1` with PowerShell 7 and Factorio 2.1.24.
- [ ] Run `pwsh -File scripts/test_upgrade.ps1 -LegacySave <path-to-2.0-save.zip>` against an isolated copy of a Factorio 2.0 save; use `-ExpectedSource <name>` when a known buffered event should be verified.
- [ ] Verify a new save, an existing save, save/load, runtime-setting changes, and both English and Polish in-game text when relevant.
- [ ] Inspect the produced ZIP: one `telemetry-mod_<version>/` root; `info.json`, `changelog.txt`, thumbnail, and both locales present; no tests, logs, saves, profiles, or editor metadata.
- [ ] Confirm the Discord relay still consumes JSONL unchanged if JSONL compatibility is part of the release.

## Publish

- [ ] Build `dist/telemetry-mod_<version>.zip` with `mod/pack-mod.ps1`.
- [ ] Upload that ZIP and `telemetry-mod/thumbnail.png` to the Factorio Mod Portal.
- [ ] Paste the reviewed English copy from `MOD_PORTAL.md`, select the Utilities category, and link the source/support URL.
- [ ] Tag or publish the matching source revision after portal validation.
