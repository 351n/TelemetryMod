const path = require('node:path');
const dgram = require('node:dgram');
const { Rcon } = require('rcon-client');
const { compare, parseJsonl, parseRcon } = require('./snapshot');

async function run(mode, directory) {
  process.env.RELAY_ENV_PATH = path.join(directory, '.env');
  process.env.RELAY_STATE_PATH = path.join(directory, 'relay_state.json');
  const relay = require('./relay');
  const state = await relay.loadState().then(() => relay.getState());
  const pollSeconds = Number(process.env.POLL_SECONDS || 15);
  if (!Number.isFinite(pollSeconds) || pollSeconds <= 0) throw new Error('POLL_SECONDS must be positive');
  const protocol = (process.env.PROTOCOL || 'sftp').toLowerCase();
  const remote = process.env.REMOTE_PATH || 'script-output/telemetry.jsonl';
  const host = process.env.RCON_HOST || '127.0.0.1';
  const rconPort = Number(process.env.RCON_PORT || 27015);
  const limit = Number(process.env.RCON_LIMIT || 100);
  const udpPort = Number(process.env.UDP_PORT || 34199);
  if (mode === 'jsonl' && !['sftp', 'ftp'].includes(protocol)) throw new Error('PROTOCOL must be sftp or ftp');
  if (mode === 'rcon' && (!Number.isInteger(limit) || limit < 1 || limit > 1000 || !Number.isInteger(rconPort) || rconPort < 1 || rconPort > 65535 || !process.env.RCON_PASSWORD)) throw new Error('Invalid RCON configuration');
  if (mode === 'udp' && (!Number.isInteger(udpPort) || udpPort < 1 || udpPort > 65535)) throw new Error('Invalid UDP_PORT');
  const identity = mode === 'jsonl' ? JSON.stringify([mode, protocol, process.env.SFTP_HOST, process.env.SFTP_PORT, process.env.SFTP_USER, process.env.FTP_HOST, process.env.FTP_PORT, process.env.FTP_USER, remote]) : JSON.stringify([mode, host, rconPort]);
  let chain = Promise.resolve();
  const serialized = fn => { chain = chain.then(fn).catch(e => console.error('Relay error:', e.message)); return chain; };
  async function quietTransition() {
    const quiet = relay.isQuietNow();
    if (state.wasQuiet && !quiet) {
      const summary = relay.buildSuppressedSummary(state.suppressedEvents || []);
      if (summary) await relay.postToDiscord(summary, 'info');
      state.suppressedEvents = [];
    }
    state.wasQuiet = quiet;
  }
  async function processSnapshot(events, tick) {
    const result = compare(state.snapshot, events, identity, state.snapshotSource, tick, state.snapshotTick);
    if (result.reset && Array.isArray(state.snapshot)) console.warn('Snapshot discontinuity; events may have been lost, establishing a new baseline');
    for (const event of result.events) await relay.handleEvent(event);
    state.snapshot = result.current; state.snapshotSource = identity; state.snapshotTick = tick;
    await relay.saveState();
  }
  if (mode === 'udp') {
    const socket = dgram.createSocket('udp4');
    socket.on('error', error => { console.error('UDP error:', error.message); process.exitCode = 1; });
    socket.on('message', data => void serialized(async () => {
      let event;
      try { event = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(data)); if (!event || typeof event !== 'object' || Array.isArray(event) || typeof event.type !== 'string') throw new Error('invalid event'); }
      catch { console.error('Invalid UDP telemetry'); return; }
      await quietTransition(); await relay.handleEvent(event); await relay.saveState();
    }));
    await new Promise((resolve, reject) => { socket.once('error', reject); socket.bind(udpPort, '127.0.0.1', () => { socket.off('error', reject); resolve(); }); });
    console.log(`UDP listening on 127.0.0.1:${udpPort}`);
    const timer = setInterval(() => void serialized(async () => { await quietTransition(); await relay.saveState(); }), pollSeconds * 1000);
    return { close: async () => { clearInterval(timer); await new Promise(resolve => socket.close(resolve)); await chain; } };
  }
  while (true) {
    await serialized(async () => {
      await quietTransition();
      if (mode === 'jsonl') {
        const result = await (protocol === 'sftp' ? relay.sftpReadRange(0) : relay.ftpReadRange(0));
        const events = parseJsonl(result.buf);
        const ticks = events.map(event => event.tick).filter(Number.isFinite);
        await processSnapshot(events, ticks.length ? Math.max(...ticks) : undefined);
      } else {
        const rcon = new Rcon({ host, port: rconPort, password: process.env.RCON_PASSWORD, timeout: 10000 });
        rcon.on('error', error => console.error('RCON connection error:', error.message));
        try { await rcon.connect(); const result = parseRcon(await rcon.send(`/telemetry-export ${limit}`)); await processSnapshot(result.events, result.tick); }
        finally { await rcon.end().catch(() => {}); }
      }
    });
    await relay.sleep(pollSeconds * 1000);
  }
}
module.exports = { run };
