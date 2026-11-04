// Compatibility launcher: implementation and dependencies now live in examples/.
const path = require('node:path');
require('../../examples/discord-shared/run').run('jsonl', path.resolve(__dirname, '..')).catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
