# Debug Checklist

## Quick Intake

Capture minimum evidence before patching:

- full error text and stack trace
- game version, mod version, and dependency versions
- exact trigger: startup, new save, save load, tick, specific action, research, map settings, config change
- reproducibility: always, intermittent, only on existing saves, only in multiplayer

## Root-Cause Triage

1. Classify stage first: settings, data, runtime, or migration.
2. Verify stage/API mismatch.
3. Identify earliest failing line and caller chain.
4. Check assumptions at that line:
- object existence (`player`, `entity`, `surface`, `force`)
- object validity (`.valid`)
- prototype existence/rename changes
- nil-safe access on optional fields

## Runtime-Specific Checks

- Confirm registration paths for all relevant events.
- Confirm handlers guard against invalid entities and disconnected players.
- Confirm `global` schema is initialized and versioned.
- Confirm no game-state mutations in `on_load`.
- Confirm remote interface names/functions are registered before use.

## Migration-Specific Checks

- Confirm migration file naming and ordering follow version changes.
- Confirm migration handles already-migrated or partially-migrated saves.
- Confirm `on_configuration_changed` does not conflict with migrations.
- Confirm old references are redirected or cleaned safely.

## Desync/MP Suspicion Checks

- Avoid nondeterministic logic in runtime handlers.
- Avoid iteration order assumptions for tables without deterministic ordering.
- Avoid per-client-only data influencing shared world state.

## Patch Selection Rule

- Choose the smallest patch that addresses the first proven failing assumption.
- Reject refactors unless needed for correctness or save safety.
- Include a targeted manual test that reproduces and verifies fix.
