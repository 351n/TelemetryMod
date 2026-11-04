require('../discord-shared/run').run('udp', __dirname).catch(e => { console.error(e.message); process.exitCode = 1; });
