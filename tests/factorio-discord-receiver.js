// Local integration receiver for the isolated Factorio smoke test.
const http = require('node:http');
const fs = require('node:fs/promises');
const path = require('node:path');

async function main() {
  const testRoot = process.argv[2];
  if (!testRoot) throw new Error('Missing test directory');
  let bridge;
  let resolveMessage;
  const received = new Promise(resolve => { resolveMessage = resolve; });
  const server = http.createServer((request, response) => {
    let body = '';
    request.setEncoding('utf8');
    request.on('data', chunk => { body += chunk; });
    request.on('end', () => {
      try {
        const payload = JSON.parse(body);
        if (payload.content.includes('factorio discord smoke')) resolveMessage(payload);
        response.writeHead(204).end();
      } catch {
        response.writeHead(400).end();
      }
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    process.env.DISCORD_WEBHOOK_URL = `http://127.0.0.1:${server.address().port}/webhook`;
    process.env.UDP_PORT = '34199';
    process.env.POLL_SECONDS = '1';
    const { run } = require('../examples/discord-shared/run');
    bridge = await run('udp', testRoot);
    await fs.writeFile(path.join(testRoot, 'discord-receiver-ready'), 'ready');
    let timeout;
    try {
      const payload = await Promise.race([
        received,
        new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('No Factorio event reached the test webhook')), 30000); })
      ]);
      if (!payload.content.includes('[smoke-discord]')) throw new Error('Webhook message is missing the Factorio source');
    } finally {
      clearTimeout(timeout);
    }
  } finally {
    if (bridge) await bridge.close();
    await new Promise(resolve => server.close(resolve));
  }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
