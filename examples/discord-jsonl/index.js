require('../discord-shared/run').run('jsonl', __dirname).catch(e => { console.error(e.message); process.exitCode = 1; });
