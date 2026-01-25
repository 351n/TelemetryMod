const fs = require('fs').promises;
const path = require('path');
const { PassThrough } = require('stream');
const dotenv = require('dotenv');
const SftpClient = require('ssh2-sftp-client');
const ftp = require('basic-ftp');
const { DateTime } = require('luxon');

dotenv.config({ path: path.resolve(__dirname, '..', '.env') });

// Config
const DISCORD_WEBHOOK_URL = process.env.DISCORD_WEBHOOK_URL;
const PROTOCOL = (process.env.PROTOCOL || 'sftp').toLowerCase();
const REMOTE_PATH = process.env.REMOTE_PATH || 'script-output/telemetry.jsonl';
const POLL_SECONDS = Number(process.env.POLL_SECONDS || 15);

const TIMEZONE = process.env.TIMEZONE || 'Europe/Warsaw';
const QUIET_HOURS_START = process.env.QUIET_HOURS_START || '23:00';
const QUIET_HOURS_END = process.env.QUIET_HOURS_END || '08:00';
const PING_ROLE_ID = process.env.PING_ROLE_ID || '';
const PING_ON_JOIN = String(process.env.PING_ON_JOIN || 'false') === 'true';
const PING_ON_CRITICAL_ONLY = String(process.env.PING_ON_CRITICAL_ONLY || 'true') === 'true';

const AFK_ON_SECONDS = Number(process.env.AFK_ON_SECONDS || 300);
const AFK_OFF_SECONDS = Number(process.env.AFK_OFF_SECONDS || 60);

// SFTP config
const SFTP_HOST = process.env.SFTP_HOST;
const SFTP_PORT = Number(process.env.SFTP_PORT || 22);
const SFTP_USER = process.env.SFTP_USER;
const SFTP_PASSWORD = process.env.SFTP_PASSWORD;
const SFTP_KEY_PATH = process.env.SFTP_KEY_PATH;

// FTP config
const FTP_HOST = process.env.FTP_HOST;
const FTP_PORT = Number(process.env.FTP_PORT || 21);
const FTP_USER = process.env.FTP_USER;
const FTP_PASS = process.env.FTP_PASS;

if (!DISCORD_WEBHOOK_URL) {
  console.error('DISCORD_WEBHOOK_URL is required');
  process.exit(1);
}

const STATE_FILE = path.resolve(__dirname, '..', 'relay_state.json');

let state = {
  offset: 0,
  carry: '',
  players: {},
  lastFileSize: 0
};

async function loadState() {
  try {
    const raw = await fs.readFile(STATE_FILE, 'utf8');
    Object.assign(state, JSON.parse(raw));
  } catch (e) {
    // missing state is ok
  }
}

async function saveState() {
  try {
    await fs.writeFile(STATE_FILE, JSON.stringify(state, null, 2), 'utf8');
  } catch (e) {
    console.error('Failed to write state:', e);
  }
}

function sleep(ms) {
  return new Promise((res) => setTimeout(res, ms));
}

async function retry(fn, name = 'operation', maxAttempts = 5) {
  let attempt = 0;
  let delay = 1000;
  while (attempt < maxAttempts) {
    try {
      return await fn();
    } catch (e) {
      attempt++;
      console.error(`${name} failed (attempt ${attempt}):`, e.message || e);
      if (attempt >= maxAttempts) throw e;
      await sleep(delay);
      delay = Math.min(15000, Math.round(delay * (attempt === 1 ? 2 : 2.5)));
    }
  }
}

function isQuietNow() {
  try {
    const now = DateTime.now().setZone(TIMEZONE);
    const [sH, sM] = QUIET_HOURS_START.split(':').map(Number);
    const [eH, eM] = QUIET_HOURS_END.split(':').map(Number);

    const start = now.set({ hour: sH, minute: sM, second: 0, millisecond: 0 });
    let end = now.set({ hour: eH, minute: eM, second: 0, millisecond: 0 });
    if (end <= start) {
      // crosses midnight -> end is next day
      end = end.plus({ days: 1 });
    }

    if (now >= start && now <= end) return true;

    // If now before end and start was yesterday (when crossing midnight)
    const startPrev = start.minus({ days: 1 });
    const endPrev = end.minus({ days: 1 });
    return now >= startPrev && now <= endPrev;
  } catch (e) {
    console.error('isQuietNow error:', e);
    return false;
  }
}

// Anti-spam: avoid sending identical messages more often than once per N seconds
const dedupMap = new Map();
const DEDUP_SECONDS = 10;

const EVOLUTION_NEW_TYPE_KEYS = new Set([
  'medium_biter',
  'small_spitter',
  'medium_worm',
  'medium_spitter',
  'big_biter_spitter_worm',
  'behemoth'
]);

function formatEvolutionPercent(value) {
  const num = Number(value);
  if (!Number.isFinite(num)) return null;
  return (Math.round(num * 1000) / 10).toFixed(1);
}

function shouldNotifyEvolutionThreshold(obj) {
  if (!obj || obj.trigger !== 'threshold') return false;
  if (obj.direction && obj.direction !== 'up') return false;
  const kind = obj.threshold_kind;
  if (kind === 'dominance') return true;
  if (kind === 'tier') {
    return EVOLUTION_NEW_TYPE_KEYS.has(obj.threshold_key);
  }
  return false;
}

async function postToDiscord(content, severity = 'info') {
  const now = Date.now();
  const last = dedupMap.get(content) || 0;
  if (now - last < DEDUP_SECONDS * 1000) return;
  dedupMap.set(content, now);

  const quiet = isQuietNow();
  const canPing = !!PING_ROLE_ID && !quiet && (!PING_ON_CRITICAL_ONLY || severity === 'critical' || (PING_ON_JOIN && severity === 'info'));

  const body = {
    content: (canPing ? `<@&${PING_ROLE_ID}> ` : '') + content,
    allowed_mentions: { parse: [] }
  };

  if (canPing) body.allowed_mentions.roles = [PING_ROLE_ID];

  await retry(async () => {
    const res = await fetch(DISCORD_WEBHOOK_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      timeout: 15000
    });
    if (!res.ok) throw new Error(`discord webhook failed: ${res.status}`);
  }, 'discord-post', 5).catch((e) => {
    console.error('Failed to post to Discord:', e.message || e);
  });
}

// SFTP read
async function sftpReadRange(offset) {
  const client = new SftpClient();
  const connectCfg = { host: SFTP_HOST, port: SFTP_PORT, username: SFTP_USER };
  if (SFTP_PASSWORD) connectCfg.password = SFTP_PASSWORD;
  if (SFTP_KEY_PATH) connectCfg.privateKey = await fs.readFile(SFTP_KEY_PATH, 'utf8');
  await client.connect(connectCfg);
  try {
    const stats = await client.stat(REMOTE_PATH);
    const size = Number(stats.size || 0);
    if (size < offset) {
      // rotation
      offset = 0;
    }
    if (size === offset) return { buf: Buffer.alloc(0), size, offset };

    // get returns Buffer when no dst specified
    const buf = await client.get(REMOTE_PATH, undefined, { start: offset, end: size - 1 });
    return { buf: Buffer.from(buf), size, offset };
  } finally {
    client.end();
  }
}

// FTP read
async function ftpReadRange(offset) {
  const client = new ftp.Client();
  client.ftp.verbose = false;
  await client.access({ host: FTP_HOST, port: FTP_PORT, user: FTP_USER, password: FTP_PASS });
  try {
    const size = await client.size(REMOTE_PATH).catch(() => 0);
    let startAt = offset;
    if (size < offset) startAt = 0;
    if (size === startAt) return { buf: Buffer.alloc(0), size, offset: startAt };

    const pass = new PassThrough();
    const chunks = [];
    pass.on('data', (c) => chunks.push(c));
    await client.downloadTo(pass, REMOTE_PATH, startAt);
    const buf = Buffer.concat(chunks);
    return { buf, size, offset: startAt };
  } finally {
    client.close();
  }
}

function handleEvent(obj) {
  try {
    if (!obj || !obj.type) return;
    const t = obj.type;
    const player = obj.player || 'unknown';

    if (t === 'join') {
      const content = `🟢 ${player} wszedł na serwer`;
      const severity = 'info';
      const shouldPing = PING_ON_JOIN && !PING_ON_CRITICAL_ONLY;
      postToDiscord(content, severity).catch(() => { });
    } else if (t === 'leave') {
      const content = `⚪ ${player} wyszedł z serwera`;
      postToDiscord(content, 'info').catch(() => { });
    } else if (t === 'afk') {
      const afkSeconds = Number(obj.afk_seconds || obj.afk_ticks || 0);
      const p = state.players[player] || { isAfk: false };
      if (!p.isAfk && afkSeconds >= AFK_ON_SECONDS) {
        p.isAfk = true;
        state.players[player] = p;
        postToDiscord(`💤 ${player} AFK`, 'warning').catch(() => { });
      } else if (p.isAfk && afkSeconds <= AFK_OFF_SECONDS) {
        p.isAfk = false;
        state.players[player] = p;
        postToDiscord(`🔔 ${player} wrócił z AFK`, 'warning').catch(() => { });
      }
    } else if (t === 'death') {
      const causeLocalised = (obj.cause_localised && String(obj.cause_localised).trim()) ? String(obj.cause_localised).trim() : '';
      const cause = causeLocalised || obj.cause || obj.cause_name || '';
      const causeType = obj.cause_type || '';
      const causeForce = obj.cause_force || '';
      const dmg = obj.damage_type || '';
      const pos = (obj.pos && Array.isArray(obj.pos) && obj.pos.length === 2) ? ` @${obj.pos[0]},${obj.pos[1]}` : '';
      let parts = [];
      const causeText = cause || 'nieznana przyczyna';
      parts.push(`${causeText}`);
      if (causeForce) parts.push(`(${causeForce})`);
      if (dmg) parts.push(`typ:${dmg}`);
      const detail = parts.length ? ` — ${parts.join(' ')}` : '';
      const content = `💀 ${player} zginął${detail}${pos}`;
      postToDiscord(content, 'critical').catch(() => { });
    } else if (t === 'research') {
      const techLocalised = (obj.technology_localised && String(obj.technology_localised).trim()) ? String(obj.technology_localised).trim() : '';
      const tech = techLocalised || obj.technology || obj.technology_name || obj.research || '';
      const techName = tech || 'nieznana technologia';
      const force = obj.force || '';
      const content = force
        ? `🔬 ${force} odkrył ${techName}`
        : `🔬 Odkryto ${techName}`;
      postToDiscord(content, 'info').catch(() => { });
    } else if (t === 'evolution') {
      if (!shouldNotifyEvolutionThreshold(obj)) return;
      const msg = (obj.message && String(obj.message).trim()) ? String(obj.message).trim() : 'Próg ewolucji obcych';
      const pct = formatEvolutionPercent(obj.evolution_factor);
      const suffix = pct ? ` (EF=${pct}%)` : '';
      const content = `🧬 ${msg}${suffix}`;
      postToDiscord(content, 'warning').catch(() => { });
    } else {
      // future events mapping
      const content = `⚠️ ${player}: ${t}`;
      postToDiscord(content, 'critical').catch(() => { });
    }
  } catch (e) {
    console.error('handleEvent error:', e);
  }
}

async function processBuffer(buf) {
  if (!buf || buf.length === 0) return 0;
  const str = buf.toString('utf8');
  const combined = state.carry + str;
  const lines = combined.split(/\r?\n/);
  // last element may be incomplete
  state.carry = lines.pop() || '';
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    try {
      const obj = JSON.parse(line);
      handleEvent(obj);
    } catch (e) {
      // ignore parse errors
    }
  }
  return Buffer.byteLength(str, 'utf8');
}

async function loop() {
  await loadState();
  console.log('Starting relay. Protocol:', PROTOCOL, 'remote:', REMOTE_PATH);

  while (true) {
    try {
      let readResult;
      if (PROTOCOL === 'sftp') {
        readResult = await retry(() => sftpReadRange(state.offset), 'sftp-read', 5);
      } else {
        readResult = await retry(() => ftpReadRange(state.offset), 'ftp-read', 5);
      }

      const { buf, size } = readResult;
      if (typeof size === 'number') {
        // rotation/truncation
        if (state.lastFileSize && size < state.lastFileSize) {
          state.offset = 0;
          state.carry = '';
        }
        state.lastFileSize = size;
      }

      const consumed = await processBuffer(buf);
      state.offset = (state.offset || 0) + consumed;
      await saveState();
    } catch (e) {
      console.error('Loop error:', e && e.message ? e.message : e);
    }
    await sleep(POLL_SECONDS * 1000);
  }
}

// Start
loop().catch((e) => {
  console.error('Fatal error:', e);
  process.exit(1);
});
