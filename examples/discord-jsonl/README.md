# Discord over JSONL

Install dependencies from `examples/` with `npm install`, copy `.env.example` to `.env` in this directory, configure the Discord webhook and existing SFTP or FTP settings, then run `node index.js` here. The first complete snapshot is a baseline and is not sent. The mod rewrites its bounded JSONL file; the bridge downloads and compares the full snapshot on each poll. A malformed or partial snapshot is rejected without advancing the baseline.

See the [examples overview](../README.md) for snapshot and port limitations.
