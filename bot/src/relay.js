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
const QUIET_HOURS_END = process.env.QUIET_HOURS_END || '09:00';
const PING_ROLE_ID = process.env.PING_ROLE_ID || '';
const PING_ON_JOIN = String(process.env.PING_ON_JOIN || 'false') === 'true';
const PING_ON_CRITICAL_ONLY = String(process.env.PING_ON_CRITICAL_ONLY || 'true') === 'true';

const AFK_ON_SECONDS = Number(process.env.AFK_ON_SECONDS || 300);
const AFK_OFF_SECONDS = Number(process.env.AFK_OFF_SECONDS || 60);

// Evolution surface whitelist (comma/space/semicolon-separated). When null, behave as today.
const EVOLUTION_NOTIFY_SURFACES_RAW = process.env.EVOLUTION_NOTIFY_SURFACES || 'navius,gleba';
const EVOLUTION_NOTIFY_SURFACES = EVOLUTION_NOTIFY_SURFACES_RAW ? EVOLUTION_NOTIFY_SURFACES_RAW.split(/[,\s;]+/).map(s => s.trim()).filter(Boolean) : null;
const EVOLUTION_NOTIFY_SURFACES_SET = EVOLUTION_NOTIFY_SURFACES ? new Set(EVOLUTION_NOTIFY_SURFACES) : null;

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

// persisted summary of suppressed events during quiet hours
state.suppressedEvents = state.suppressedEvents || [];
state.wasQuiet = state.wasQuiet || false;
// persisted sent ids for dedupe across restarts and last seen tick
state.sentEventIds = state.sentEventIds || [];
state.lastTick = state.lastTick || 0;

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

// persistent dedupe: keep a capped list of recently-sent event ids across restarts
const MAX_SENT_IDS = 2000;
let sentIdSet = new Set();

const EVOLUTION_NEW_TYPE_KEYS = new Set([
  'medium_biter',
  'small_spitter',
  'medium_worm',
  'medium_spitter',
  'big_biter_spitter_worm',
  'behemoth',
  'tier_1',
  'tier_2',
  'tier_3',
  'tier_4',
  'tier_5',
  'tier_6',
  'tier_7',
  'tier_8',
  'tier_9',
  'tier_10',
  'tier_10_50',
  'tier_10_75'
]);

function formatEvolutionPercent(value) {
  const num = Number(value);
  if (!Number.isFinite(num)) return null;
  return (Math.round(num * 1000) / 10).toFixed(1);
}

function shouldNotifyEvolutionThreshold(obj) {
  if (!obj || obj.trigger !== 'threshold') return false;
  // If an allowed-surface list is configured, only notify thresholds for those surfaces.
  if (EVOLUTION_NOTIFY_SURFACES_SET) {
    const surf = (obj.surface || '').toString();
    if (!surf || !EVOLUTION_NOTIFY_SURFACES_SET.has(surf)) return false;
  }
  if (obj.direction && obj.direction !== 'up') return false;
  const kind = obj.threshold_kind;
  if (kind === 'dominance') return true;
  if (kind === 'tier') {
    const key = obj.threshold_key ? String(obj.threshold_key) : '';
    return EVOLUTION_NEW_TYPE_KEYS.has(key) || key.startsWith('tier_');
  }
  return false;
}

// Build a stable id for an event to deduplicate across rotations/restarts.
// Uses `tick` when available plus a small type-specific key.
function getEventId(obj) {
  if (!obj || !obj.type) return null;
  const tick = (typeof obj.tick !== 'undefined') ? String(obj.tick) : '0';
  const type = obj.type;
  let key = '';
  if (type === 'research') key = (obj.technology_localised || obj.technology || '').trim();
  else if (type === 'death') key = `${(obj.player||'')}:${(obj.cause_localised||obj.cause||'')}:${JSON.stringify(obj.pos||'')}`;
  else if (type === 'join' || type === 'leave' || type === 'afk') key = (obj.player || '');
  else if (type === 'evolution') {
    const base = (obj.threshold_kind || obj.trigger || obj.message || '');
    const surf = (obj.surface || '');
    key = `${base}:${surf}`;
  }
  else key = JSON.stringify([obj.type, obj.player || '', obj.technology || obj.message || '']).slice(0, 200);
  return `${tick}|${type}|${key}`;
}

function buildSuppressedSummary(events) {
  if (!events || !events.length) return null;
  const researchSet = new Set();
  let deathCount = 0;
  const deathPlayers = [];
  const others = [];

  for (const e of events) {
    const meta = e.meta || {};
    const content = e.content || '';
    if (meta.type === 'research' && meta.tech) {
      researchSet.add(meta.tech);
    } else if (meta.type === 'death') {
      deathCount++;
      if (meta.player) deathPlayers.push(meta.player);
    } else if (content && content.startsWith('🔬')) {
      // try to parse tech name
      const m = content.match(/(?:odkrył|Odkryto)\s+(.+)$/i);
      if (m && m[1]) researchSet.add(m[1].trim()); else others.push(content);
    } else if (content && content.startsWith('💀')) {
      deathCount++;
      const m = content.match(/💀\s+([^\s]+)\s/);
      if (m && m[1]) deathPlayers.push(m[1]);
    } else {
      others.push(content);
    }
  }

  let lines = [];
  lines.push('Podsumowanie z quiet hours:');
  if (researchSet.size) {
    lines.push('Odkryte technologie:');
    for (const t of researchSet) lines.push(`- ${t}`);
  }
  if (deathCount) {
    lines.push(`Śmierci graczy: ${deathCount}` + (deathPlayers.length ? ` (lista: ${[...new Set(deathPlayers)].join(', ')})` : ''));
  }
  if (others.length) {
    lines.push('Inne zdarzenia:');
    for (const o of others.slice(0, 10)) lines.push(`- ${o}`);
    if (others.length > 10) lines.push(`... i ${others.length - 10} innych`);
  }

  return lines.join('\n');
}

async function postToDiscord(content, severity = 'info', meta = null) {
  const now = Date.now();

  const quiet = isQuietNow();
  // During quiet hours only allow critical messages through; record suppressed events
  if (quiet && severity !== 'critical') {
    try {
      state.suppressedEvents = state.suppressedEvents || [];
      state.suppressedEvents.push({ time: now, severity, content, meta });
      await saveState();
    } catch (e) {
      // ignore save errors
    }
    return;
  }

  const last = dedupMap.get(content) || 0;
  if (now - last < DEDUP_SECONDS * 1000) return;
  dedupMap.set(content, now);

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

    function notify(content, severity = 'info') {
      postToDiscord(content, severity).catch(() => { });
    }

    const handlers = {
      join: () => notify(`🟢 ${player} wszedł na serwer`, 'critical'),
      leave: () => notify(`⚪ ${player} wyszedł z serwera`, 'critical'),
      afk: () => {
        const afkSeconds = Number(obj.afk_seconds || obj.afk_ticks || 0);
        const p = state.players[player] || { isAfk: false };
        if (!p.isAfk && afkSeconds >= AFK_ON_SECONDS) {
          p.isAfk = true;
          state.players[player] = p;
          notify(`💤 ${player} AFK`, 'warning', { type: 'afk', player });
        } else if (p.isAfk && afkSeconds <= AFK_OFF_SECONDS) {
          p.isAfk = false;
          state.players[player] = p;
          notify(`🔔 ${player} wrócił z AFK`, 'warning', { type: 'afk', player });
        }
      },
      death: () => {
        const causeLocalised = (obj.cause_localised && String(obj.cause_localised).trim()) ? String(obj.cause_localised).trim() : '';
        const cause = causeLocalised || obj.cause || obj.cause_name || '';
        const causeForce = obj.cause_force || '';
        const dmg = obj.damage_type || '';
        const pos = (obj.pos && Array.isArray(obj.pos) && obj.pos.length === 2) ? ` @${obj.pos[0]},${obj.pos[1]}` : '';
        const causeText = cause || 'nieznana przyczyna';
        const parts = [causeText];
        if (causeForce) parts.push(`(${causeForce})`);
        if (dmg) parts.push(`typ:${dmg}`);
        const detail = parts.length ? ` — ${parts.join(' ')}` : '';
        notify(`💀 ${player} zginął${detail}${pos}`, 'info', { type: 'death', player, detail });
      },
      research: () => {
        const techLocalised = (obj.technology_localised && String(obj.technology_localised).trim()) ? String(obj.technology_localised).trim() : '';
        const tech = techLocalised || obj.technology || obj.technology_name || obj.research || '';
        const techName = tech || 'nieznana technologia';
        const force = obj.force || '';
        const content = (force && force != 'player')
          ? `🔬 ${force} odkrył ${techName}`
          : `🔬 Odkryto ${techName}`;
        notify(content, 'info', { type: 'research', tech: techName });
      },
      evolution: () => {
        if (!shouldNotifyEvolutionThreshold(obj)) return;
        const msg = (obj.message && String(obj.message).trim()) ? String(obj.message).trim() : 'Próg ewolucji obcych';
        const pct = formatEvolutionPercent(obj.evolution_factor);
        const suffix = pct ? ` (EF=${pct}%)` : '';
        const surface = obj.surface || '';
        const surfaceSuffix = surface ? ` on ${surface}` : '';
        notify(`🧬 ${msg}${suffix}${surfaceSuffix}`, 'critical', { type: 'evolution', surface: surface });
      }
    };

    if (handlers[t]) {
      // use notify wrapper that attaches meta
      function notify(content, severity = 'info', meta = null) {
        postToDiscord(content, severity, meta);
      }
      handlers[t]();
    } else {
      postToDiscord(`⚠️ ${player}: ${t}`, 'critical', { type: 'unknown', event: t });
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

      // detect tick reset / server restart: if tick decreases drastically, clear sent ids
      if (typeof obj.tick === 'number') {
        if (state.lastTick && obj.tick + 1000000 < state.lastTick) {
          // significant decrease -> assume restart/semantic reset
          state.sentEventIds = [];
          sentIdSet.clear();
          console.log('Detected tick reset / restart — clearing cached sent event ids');
        }
        state.lastTick = Math.max(state.lastTick || 0, obj.tick);
      }

      // dedupe using persisted sent ids
      const id = getEventId(obj);
      if (id && sentIdSet.has(id)) continue;

      // mark as seen and persist a capped list
      if (id) {
        sentIdSet.add(id);
        state.sentEventIds = state.sentEventIds || [];
        state.sentEventIds.unshift(id);
        if (state.sentEventIds.length > MAX_SENT_IDS) state.sentEventIds.length = MAX_SENT_IDS;
        // persist async
        saveState().catch(() => {});
      }

      handleEvent(obj);
    } catch (e) {
      // ignore parse errors
    }
  }
  return Buffer.byteLength(str, 'utf8');
}

async function loop() {
  await loadState();
  // rebuild in-memory set after loading persisted state
  sentIdSet = new Set(state.sentEventIds || []);
  console.log('Starting relay. Protocol:', PROTOCOL, 'remote:', REMOTE_PATH);
  // initialize wasQuiet from current time if not present
  state.wasQuiet = state.wasQuiet || isQuietNow();
  await saveState();

  while (true) {
    try {
      // check quiet-hours transition: if we were quiet and now are not, post summary
      const nowQuiet = isQuietNow();
      if (state.wasQuiet && !nowQuiet) {
        try {
          if (state.suppressedEvents && state.suppressedEvents.length) {
            const summary = buildSuppressedSummary(state.suppressedEvents);
            if (summary) await postToDiscord(summary, 'info');
          }
        } catch (e) {
          console.error('Error sending quiet-hours summary:', e);
        }
        state.suppressedEvents = [];
        await saveState();
      }
      state.wasQuiet = nowQuiet;

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
