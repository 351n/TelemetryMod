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
const STATE_MAX_SENT_IDS = Math.max(100, Number(process.env.STATE_MAX_SENT_IDS || 800));
const STATE_MAX_SUPPRESSED_EVENTS = Math.max(50, Number(process.env.STATE_MAX_SUPPRESSED_EVENTS || 500));
const STATE_MAX_CARRY_BYTES = Math.max(1024, Number(process.env.STATE_MAX_CARRY_BYTES || 32768));
const STATE_PLAYER_STALE_HOURS = Math.max(1, Number(process.env.STATE_PLAYER_STALE_HOURS || (7 * 24)));
const STATE_MAX_PLAYERS = Math.max(10, Number(process.env.STATE_MAX_PLAYERS || 200));

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

function normalizePlayerStateEntry(entry, nowTs) {
  const isAfk = !!(entry && entry.isAfk);
  const rawLastSeen = Number(entry && entry.lastSeenTs);
  const lastSeenTs = Number.isFinite(rawLastSeen) && rawLastSeen > 0 ? rawLastSeen : nowTs;
  return { isAfk, lastSeenTs };
}

function trimState() {
  const now = Date.now();

  if (typeof state.offset !== 'number' || !Number.isFinite(state.offset) || state.offset < 0) {
    state.offset = 0;
  }
  if (typeof state.lastFileSize !== 'number' || !Number.isFinite(state.lastFileSize) || state.lastFileSize < 0) {
    state.lastFileSize = 0;
  }
  if (typeof state.lastTick !== 'number' || !Number.isFinite(state.lastTick) || state.lastTick < 0) {
    state.lastTick = 0;
  }

  if (typeof state.carry !== 'string') state.carry = '';
  if (state.carry.length > STATE_MAX_CARRY_BYTES) {
    state.carry = state.carry.slice(-STATE_MAX_CARRY_BYTES);
  }

  if (!Array.isArray(state.suppressedEvents)) state.suppressedEvents = [];
  if (state.suppressedEvents.length > STATE_MAX_SUPPRESSED_EVENTS) {
    state.suppressedEvents = state.suppressedEvents.slice(-STATE_MAX_SUPPRESSED_EVENTS);
  }

  if (!Array.isArray(state.sentEventIds)) state.sentEventIds = [];
  const uniqueSentIds = [];
  const seenSentIds = new Set();
  for (const id of state.sentEventIds) {
    if (typeof id !== 'string' || !id) continue;
    if (seenSentIds.has(id)) continue;
    seenSentIds.add(id);
    uniqueSentIds.push(id);
    if (uniqueSentIds.length >= STATE_MAX_SENT_IDS) break;
  }
  state.sentEventIds = uniqueSentIds;

  const playersObj = (state.players && typeof state.players === 'object' && !Array.isArray(state.players))
    ? state.players
    : {};
  const staleMs = STATE_PLAYER_STALE_HOURS * 60 * 60 * 1000;
  const players = Object.entries(playersObj).map(([name, entry]) => ({
    name,
    ...normalizePlayerStateEntry(entry, now)
  }));
  players.sort((a, b) => b.lastSeenTs - a.lastSeenTs);

  const nextPlayers = {};
  let kept = 0;
  for (const p of players) {
    const stale = (now - p.lastSeenTs) > staleMs;
    if (!p.isAfk && stale) continue;
    if (kept >= STATE_MAX_PLAYERS && !p.isAfk) continue;
    nextPlayers[p.name] = { isAfk: p.isAfk, lastSeenTs: p.lastSeenTs };
    kept++;
  }
  state.players = nextPlayers;

  // Keep in-memory dedupe map consistent with persisted ids after trimming.
  if (typeof sentIdSet !== 'undefined' && sentIdSet instanceof Set) {
    sentIdSet = new Set(state.sentEventIds);
  }
}

async function loadState() {
  try {
    const raw = await fs.readFile(STATE_FILE, 'utf8');
    Object.assign(state, JSON.parse(raw));
  } catch (e) {
    // missing state is ok
  }
  trimState();
}

async function saveState() {
  try {
    trimState();
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
let sentIdSet = new Set();
const PERSISTED_DEDUPE_TYPES = new Set(['join', 'leave', 'desync', 'death', 'research', 'evolution', 'notify']);

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

function normalizeNotifySeverity(value) {
  const raw = String(value || 'info').toLowerCase();
  if (raw === 'warn') return 'warning';
  if (raw === 'error' || raw === 'fatal') return 'critical';
  if (raw === 'warning' || raw === 'critical') return raw;
  return 'info';
}

function shouldPersistEventId(obj) {
  if (!obj || !obj.type) return false;
  return PERSISTED_DEDUPE_TYPES.has(obj.type);
}

// Build a stable id for an event to deduplicate across rotations/restarts.
// Uses `tick` when available plus a small type-specific key.
function getEventId(obj) {
  if (!obj || !obj.type) return null;
  const tick = (typeof obj.tick !== 'undefined') ? String(obj.tick) : '0';
  const type = obj.type;
  let key = '';
  if (type === 'research') key = (obj.technology_localised || obj.technology || '').trim();
  else if (type === 'death') key = `${(obj.player||'')}:${(obj.cause_localised||obj.cause||'')}:${JSON.stringify(obj.pos||'')}:${(obj.surface||'')}`;
  else if (type === 'join' || type === 'leave' || type === 'afk') key = (obj.player || '');
  else if (type === 'desync') {
    const reasonKey = (obj.reason !== undefined && obj.reason !== null && obj.reason !== '')
      ? obj.reason
      : (obj.reason_id !== undefined ? obj.reason_id : '');
    key = `${(obj.player || '')}:${reasonKey}`;
  }
  else if (type === 'evolution') {
    const base = (obj.threshold_kind || obj.trigger || obj.message || '');
    const surf = (obj.surface || '');
    key = `${base}:${surf}`;
  }
  else if (type === 'notify') {
    key = `${(obj.source || '')}:${(obj.severity || obj.level || '')}:${(obj.message || obj.text || '')}`.slice(0, 200);
  }
  else key = JSON.stringify([obj.type, obj.player || '', obj.technology || obj.message || '']).slice(0, 200);
  return `${tick}|${type}|${key}`;
}

function isSuppressedAfkEvent(event) {
  if (!event) return false;
  const metaType = event.meta && event.meta.type ? String(event.meta.type) : '';
  if (metaType === 'afk') return true;

  // Backward compatibility: older entries might not have meta.
  const content = String(event.content || '');
  return /\bAFK\b/i.test(content);
}

function buildSuppressedSummary(events) {
  if (!events || !events.length) return null;
  const researchSet = new Set();
  let deathCount = 0;
  const deathPlayers = [];
  let notifyCount = 0;
  const notifySources = new Map();
  const others = [];

  for (const e of events) {
    if (isSuppressedAfkEvent(e)) {
      continue;
    }

    const meta = e.meta || {};
    const content = e.content || '';

    if (meta.type === 'research') {
      if (meta.tech) {
        researchSet.add(meta.tech);
      } else if (content) {
        others.push(content);
      }
      continue;
    }

    if (meta.type === 'death') {
      deathCount++;
      if (meta.player) deathPlayers.push(meta.player);
      continue;
    }

    if (meta.type === 'notify') {
      notifyCount++;
      const source = (meta.source && String(meta.source).trim()) || 'external';
      notifySources.set(source, (notifySources.get(source) || 0) + 1);
      continue;
    }

    if (content) {
      others.push(content);
    }
  }

  if (!researchSet.size && !deathCount && !notifyCount && !others.length) {
    return null;
  }

  let lines = [];
  lines.push('Podsumowanie z quiet hours:');
  if (researchSet.size) {
    lines.push('Odkryte technologie:');
    for (const t of researchSet) lines.push(`- ${t}`);
  }
  if (deathCount) {
    const uniqPlayers = [...new Set(deathPlayers)];
    const playersSuffix = uniqPlayers.length ? ` (lista: ${uniqPlayers.join(', ')})` : '';
    lines.push(`Smierci graczy: ${deathCount}${playersSuffix}`);
  }
  if (notifyCount) {
    lines.push(`Powiadomienia telemetryczne: ${notifyCount}`);
    const topSources = [...notifySources.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5);
    for (const [source, count] of topSources) {
      lines.push(`- ${source}: ${count}`);
    }
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
    const isAfkMeta = meta && meta.type === 'afk';
    if (isAfkMeta) {
      return;
    }
    try {
      state.suppressedEvents = state.suppressedEvents || [];
      state.suppressedEvents.push({ time: now, severity, content, meta });
      if (state.suppressedEvents.length > STATE_MAX_SUPPRESSED_EVENTS) {
        state.suppressedEvents = state.suppressedEvents.slice(-STATE_MAX_SUPPRESSED_EVENTS);
      }
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

    const notify = (content, severity = 'info', meta = null) => {
      postToDiscord(content, severity, meta).catch(() => { });
    };

    const handlers = {
      join: () => notify(`[JOIN] ${player} wszedl na serwer`, 'critical'),
      leave: () => notify(`[LEAVE] ${player} wyszedl z serwera`, 'critical'),
      desync: () => {
        const reason = (obj.reason && String(obj.reason).trim()) ? String(obj.reason).trim() : '';
        const reasonIdRaw = Number(obj.reason_id);
        const reasonId = Number.isFinite(reasonIdRaw) ? reasonIdRaw : null;
        const reasonBits = [];
        if (reason) reasonBits.push(reason);
        if (reasonId !== null) reasonBits.push(`id:${reasonId}`);
        const reasonSuffix = reasonBits.length ? ` (${reasonBits.join(', ')})` : '';
        notify(`[DESYNC] ${player} rozlaczyl sie przez desync${reasonSuffix}`, 'critical');
      },
      afk: () => {
        const afkSeconds = Number(obj.afk_seconds || obj.afk_ticks || 0);
        const p = normalizePlayerStateEntry(state.players[player], Date.now());
        p.lastSeenTs = Date.now();
        state.players[player] = p;
        if (!p.isAfk && afkSeconds >= AFK_ON_SECONDS) {
          p.isAfk = true;
          notify(`[AFK] ${player} AFK`, 'warning', { type: 'afk', player });
        } else if (p.isAfk && afkSeconds <= AFK_OFF_SECONDS) {
          p.isAfk = false;
          notify(`[AFK] ${player} wrocil z AFK`, 'warning', { type: 'afk', player });
        }
      },
      death: () => {
        const causeLocalised = (obj.cause_localised && String(obj.cause_localised).trim()) ? String(obj.cause_localised).trim() : '';
        const cause = causeLocalised || obj.cause || obj.cause_name || '';
        const causeForce = obj.cause_force || '';
        const dmg = obj.damage_type || '';
        const surface = (obj.surface && String(obj.surface).trim()) ? String(obj.surface).trim() : '';
        const pos = (obj.pos && Array.isArray(obj.pos) && obj.pos.length === 2) ? ` @${obj.pos[0]},${obj.pos[1]}` : '';
        const surfaceSuffix = surface ? ` [${surface}]` : '';
        const causeText = cause || 'nieznana przyczyna';
        const parts = [causeText];
        if (causeForce) parts.push(`(${causeForce})`);
        if (dmg) parts.push(`typ:${dmg}`);
        const detail = parts.length ? ` - ${parts.join(' ')}` : '';
        notify(`[DEATH] ${player} zginal${detail}${pos}${surfaceSuffix}`, 'info', { type: 'death', player, detail, surface });
      },
      research: () => {
        const techLocalised = (obj.technology_localised && String(obj.technology_localised).trim()) ? String(obj.technology_localised).trim() : '';
        const tech = techLocalised || obj.technology || obj.technology_name || obj.research || '';
        const techName = tech || 'nieznana technologia';
        const force = obj.force || '';
        const content = (force && force != 'player')
          ? `[RESEARCH] ${force} odkryl ${techName}`
          : `[RESEARCH] Odkryto ${techName}`;
        notify(content, 'info', { type: 'research', tech: techName });
      },
      evolution: () => {
        if (!shouldNotifyEvolutionThreshold(obj)) return;
        const msg = (obj.message && String(obj.message).trim()) ? String(obj.message).trim() : 'Prog ewolucji obcych';
        const pct = formatEvolutionPercent(obj.evolution_factor);
        const suffix = pct ? ` (EF=${pct}%)` : '';
        const surface = obj.surface || '';
        const surfaceSuffix = surface ? ` on ${surface}` : '';
        notify(`[EVOLUTION] ${msg}${suffix}${surfaceSuffix}`, 'critical', { type: 'evolution', surface: surface });
      },
      notify: () => {
        const message = (obj.message && String(obj.message).trim())
          ? String(obj.message).trim()
          : ((obj.text && String(obj.text).trim()) ? String(obj.text).trim() : '');
        if (!message) return;
        const source = (obj.source && String(obj.source).trim()) ? String(obj.source).trim() : 'external';
        const severity = normalizeNotifySeverity(obj.severity || obj.level);
        const surface = (obj.surface && String(obj.surface).trim()) ? String(obj.surface).trim() : '';
        const surfaceSuffix = surface ? ` [${surface}]` : '';
        notify(`[NOTIFY] [${source}] ${message}${surfaceSuffix}`, severity, { type: 'notify', source, severity });
      }
    };

    if (handlers[t]) {
      handlers[t]();
    } else {
      notify(`[UNKNOWN] ${player}: ${t}`, 'critical', { type: 'unknown', event: t });
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
          console.log('Detected tick reset / restart - clearing cached sent event ids');
        }
        state.lastTick = Math.max(state.lastTick || 0, obj.tick);
      }

      // dedupe using persisted sent ids
      const id = getEventId(obj);
      const persistId = id && shouldPersistEventId(obj);
      if (persistId && sentIdSet.has(id)) continue;

      // mark as seen and persist a capped list
      if (persistId) {
        sentIdSet.add(id);
        state.sentEventIds = state.sentEventIds || [];
        state.sentEventIds.unshift(id);
        if (state.sentEventIds.length > STATE_MAX_SENT_IDS) state.sentEventIds.length = STATE_MAX_SENT_IDS;
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

