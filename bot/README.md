# Legacy Discord launcher

The implementation is now in [examples/discord-jsonl](../examples/discord-jsonl/README.md). This directory retains a compatibility launcher for existing local setups; the user's `.env`, `relay_state.json`, launcher configuration and sample data remain in place.

Install the shared dependencies with `npm install` in `examples/`, then the existing `node bot/src/relay.js` launcher uses `bot/.env` and `bot/relay_state.json`. Its first complete JSONL snapshot becomes a new baseline. To migrate fully, copy `.env` manually into `examples/discord-jsonl/` and start that example; state is not migrated automatically.
