# Save Compatibility

## Risk Levels

Use one clear risk label in every response.

1. Low
- Runtime guard fixes (`nil` checks, validity checks)
- Event registration corrections with no schema or prototype identity changes
- Non-breaking logic fixes that do not alter persistent keys

2. Medium
- `global` schema shape changes with safe migration path
- Controlled behavior changes affecting existing entities/forces
- Adjustments requiring `on_configuration_changed` upgrade code

3. High
- Prototype renames/removals without compatibility shims
- Changes that orphan existing entities/items/recipes/technologies
- Migration logic that can delete, duplicate, or corrupt persistent state

## Required Save-Safety Review

For each proposed patch, evaluate:

- existing-save impact: does old `global` data remain readable
- migration requirement: need for `migrations/*` and/or `on_configuration_changed`
- rollback risk: what happens if user downgrades or removes the mod
- multiplayer risk: deterministic behavior and identical state transitions

## Safe Patterns

- Add defensive reads for missing fields before writing new schema.
- Version `global` schema and upgrade incrementally.
- Keep migrations idempotent and guarded.
- Preserve old keys temporarily when uncertainty exists.

## Unsafe Patterns

- Reinitialize full `global` unconditionally in existing saves.
- Rename/remove prototypes used by existing saves without migration handling.
- Assume all saves come from immediately previous version only.

## Minimal Test Matrix

Run manual checks on:

1. New save with mod enabled.
2. Existing save from previous released version.
3. Existing save that skips one or more versions (if relevant).
4. Multiplayer load/rejoin path when issue touches runtime events.
