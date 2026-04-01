# Factorio Lifecycle

## Stages

1. Settings stage
- Files: `settings.lua`, `settings-updates.lua`, `settings-final-fixes.lua`
- Purpose: define startup/map/runtime settings prototypes
- Do not use runtime globals (`game`, `script`, `global`)

2. Prototype (data) stage
- Files: `data.lua`, `data-updates.lua`, `data-final-fixes.lua`
- Purpose: define and modify prototypes, recipes, technologies, items, entities
- Do not read runtime state; no `game`, `script`, or `global`

3. Runtime (control) stage
- File: `control.lua` plus required runtime modules
- Purpose: react to events, maintain `global`, mutate world state through Lua runtime API
- Use event handlers and lifecycle hooks correctly (`on_init`, `on_load`, `on_configuration_changed`)

4. Migration stage
- Files: `migrations/*.lua` plus version change logic
- Purpose: update existing saves between mod versions
- Design migrations to be idempotent and safe for partial historical states

## Common Stage-Mixing Failures

- Accessing `game` or `global` inside `data.lua` or `settings.lua`
- Calling `data:extend` from runtime code
- Assuming prototype edits after save load can fix runtime-only state
- Relying on runtime-created names without a migration path

## Stage Identification Heuristics

- Errors mentioning prototype keys or missing prototype types usually indicate data stage.
- Errors mentioning `global`, `script`, `defines.events`, nil player/entity, or invalid object usually indicate runtime stage.
- Errors appearing only after updating mod version or loading old saves usually indicate migration/configuration-changed path.

## Lifecycle Reminders

- `on_init`: initialize `global` once for new saves.
- `on_load`: restore metatables/cached function references only; do not mutate game state.
- `on_configuration_changed`: perform version-aware upgrades for existing saves.
- `migrations/*`: use for deterministic save upgrades keyed by version transitions.
