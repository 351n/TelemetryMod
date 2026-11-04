const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const dgram = require('node:dgram');
const net = require('node:net');
const { Rcon } = require('rcon-client');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { compare, parseJsonl, parseRcon } = require('./snapshot');
const a = { type: 'join', tick: 1, player: 'a' }, b = { type: 'death', tick: 2, player: 'b' }, c = { type: 'research', tick: 3 };

test('snapshots baseline, overlap, no overlap, reset and source change', () => {
  const first = compare(null, [a,b], 'a', null, 2, null);
  assert.deepEqual(first.events, []);
  assert.deepEqual(compare(first.current, [b,c], 'a', 'a', 3, 2).events, [c]);
  assert.deepEqual(compare(first.current, [a,b,c], 'a', 'a', 3, 2).events, [c]);
  assert.deepEqual(compare(first.current, [c], 'a', 'a', 3, 2).events, []);
  assert.equal(compare(first.current, [a,b], 'a', 'a', 1, 2).reset, true);
  assert.equal(compare(first.current, [a,b], 'b', 'a', 3, 2).reset, true);
  assert.deepEqual(compare([], [a], 'a', 'a', 1, 0).events, [a]);
  assert.deepEqual(compare(first.current, [a,b], 'a', 'a', 2, 2).events, []);
});
test('parsers reject partial JSONL and invalid RCON envelopes', () => {
  assert.deepEqual(parseJsonl(Buffer.from(JSON.stringify(a)+'\n')), [a]);
  assert.throws(() => parseJsonl(Buffer.from('{"type":')));
  assert.throws(() => parseJsonl(Buffer.from('{"type":"x"}')));
  assert.throws(() => parseRcon('{"schema":"telemetry-rcon/v1","tick":1,"events":[],"error":"rcon-disabled"}'));
  assert.throws(() => parseRcon('{"schema":"wrong","tick":1,"events":[]}'));
  assert.equal(parseRcon('{"schema":"telemetry-rcon/v1","tick":1,"events":[]}').tick, 1);
});
test('RCON client reads a snapshot from a local protocol server', async t => {
  const commands = [];
  const server = net.createServer(socket => {
    let data = Buffer.alloc(0);
    socket.on('data', chunk => {
      data = Buffer.concat([data, chunk]);
      while (data.length >= 4 && data.length >= data.readInt32LE(0) + 4) {
        const length = data.readInt32LE(0), packet = data.subarray(0, length + 4);
        data = data.subarray(length + 4);
        const id = packet.readInt32LE(4), type = packet.readInt32LE(8);
        const command = packet.subarray(12, -2).toString('utf8');
        const payload = type === 3 ? '' : JSON.stringify({ schema: 'telemetry-rcon/v1', tick: 2, events: [a,b] });
        if (type !== 3) commands.push(command);
        const bytes = Buffer.from(payload), reply = Buffer.alloc(bytes.length + 14);
        reply.writeInt32LE(bytes.length + 10, 0); reply.writeInt32LE(id, 4); reply.writeInt32LE(type === 3 ? 2 : 0, 8); bytes.copy(reply, 12); socket.write(reply);
      }
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const rcon = new Rcon({ host: '127.0.0.1', port: server.address().port, password: 'test', timeout: 1000 });
  rcon.on('error', () => {});
  await rcon.connect();
  const result = parseRcon(await rcon.send('/telemetry-export 100'));
  await rcon.end();
  assert.deepEqual(commands, ['/telemetry-export 100']); assert.deepEqual(result.events, [a,b]);
});
test('UDP event reaches local Discord webhook', async t => {
  const received = [];
  const server = http.createServer((req, res) => { let body=''; req.on('data', x => body += x); req.on('end', () => { received.push(JSON.parse(body)); res.writeHead(204).end(); }); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'telemetry-discord-test-'));
  process.env.DISCORD_WEBHOOK_URL = `http://127.0.0.1:${server.address().port}/webhook`;
  process.env.UDP_PORT = '37973'; process.env.QUIET_HOURS_START = '00:00'; process.env.QUIET_HOURS_END = '00:01';
  const { run } = require('./run');
  const relay = await run('udp', tmp);
  const client = dgram.createSocket('udp4');
  t.after(async () => { client.close(); await relay.close(); await new Promise(resolve => server.close(resolve)); await fs.rm(tmp, { recursive: true, force: true }); });
  await new Promise((resolve, reject) => client.send(Buffer.from(JSON.stringify(a)), 37973, '127.0.0.1', e => e ? reject(e) : resolve()));
  for (let i=0; i<50 && !received.length; i++) await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(received.length, 1);
  assert.match(received[0].content, /a wszedl na serwer/);
  assert.deepEqual(received[0].allowed_mentions, { parse: [] });
});
