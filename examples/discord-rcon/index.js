require('../discord-shared/run').run('rcon', __dirname).catch(e => { console.error(e.message); process.exitCode = 1; });
