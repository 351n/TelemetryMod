---
name: factorio-mod-debug
description: Diagnose and fix Factorio mod bugs with the smallest safe patch and explicit save-compatibility analysis. Use when tasks mention Factorio crashes, stack traces, error messages, regressions, incorrect behavior, desync suspicion, broken save/load, or debugging control.lua, data.lua, data-updates.lua, data-final-fixes.lua, settings.lua, or migrations/*. Use when asked to find root cause, explain a Factorio mod error, or propose the smallest safe fix. Do not use for general Lua review unrelated to Factorio, style-only review, or implementing brand new features from scratch.
---

# Factorio Mod Debug

Diagnose Factorio mod failures by stage, verify API/stage correctness, and propose minimal save-safe fixes.

## Workflow

1. Classify the execution stage first.
2. Validate stage/API boundaries before deeper debugging.
3. Reconstruct the failing path and isolate the most probable root cause.
4. Assess save compatibility impact before proposing changes.
5. Propose the smallest safe patch and a focused verification plan.
6. State missing evidence and next checks when confidence is limited.

## Stage Classification (Always First)

Map the issue to one primary stage, then note any cross-stage interactions:

- `settings` stage: `settings.lua`, `settings-updates.lua`, `settings-final-fixes.lua`
- prototype/data stage: `data.lua`, `data-updates.lua`, `data-final-fixes.lua`
- runtime/control stage: `control.lua`, runtime scripts, event handlers, remote interface calls
- migration stage: `migrations/*`, `on_configuration_changed`, version bumps

If the report includes multiple files, identify the first failing stage and explain the chain.

## Mandatory Diagnostic Checks

Run these checks explicitly whenever relevant:

1. Stage/API mismatch
- Detect data-stage APIs used in runtime code, or runtime-only objects (`game`, `script`, `global`) used in data/settings stages.
- Detect prototype assumptions leaked into runtime logic or vice versa.

2. Event and lifecycle correctness (runtime)
- Verify `script.on_init`, `script.on_load`, and `script.on_configuration_changed` responsibilities.
- Verify event registration paths (`script.on_event`, `script.on_nth_tick`) and handler assumptions about entity validity, player existence, and surface state.
- Verify `global` initialization and schema upgrades across versions.
- Verify remote interfaces: registration timing, exposed function contracts, and caller expectations.

3. Migration correctness
- Verify migration ordering, idempotency, and guards for partially-upgraded saves.
- Verify compatibility between `migrations/*` changes and `on_configuration_changed`.
- Verify references to renamed/removed prototypes, forces, technologies, recipes, and items.

4. Regression isolation
- Compare behavior against last known good version.
- Identify exact trigger (load, tick, build event, config change, research completion, etc.).
- Prefer one minimal fix that addresses the trigger over broad rewrites.

## Fixing Rules

- Prefer the smallest safe patch over refactors.
- Preserve behavior outside the failing path.
- Avoid introducing new persistent state unless required.
- If evidence is incomplete, state exactly what logs/files/repro steps are missing and what to check next.

## Required Output Format

Return results with these exact sections in this order:

1. probable root cause
2. confidence level
3. affected files/stages
4. minimal patch suggestion
5. save compatibility risk
6. manual test plan
7. follow-up checks

## References

Load only what is needed:

- `references/factorio-lifecycle.md` for stage boundaries and allowed APIs.
- `references/debug-checklist.md` for rapid triage and root-cause checklist.
- `references/save-compatibility.md` for risk grading and upgrade safety rules.
