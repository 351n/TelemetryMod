const crypto = require('node:crypto');

function fingerprint(event) {
  return crypto.createHash('sha256').update(JSON.stringify(event)).digest('hex');
}
function compare(previous, events, source, previousSource, tick, previousTick) {
  const current = events.map(fingerprint);
  if (!Array.isArray(previous) || source !== previousSource || (Number.isFinite(tick) && Number.isFinite(previousTick) && tick < previousTick)) {
    return { current, events: [], reset: true };
  }
  if (!previous.length) return { current, events, reset: false };
  if (!current.length) return { current, events: [], reset: true };
  let overlap = Math.min(previous.length, current.length);
  while (overlap && !previous.slice(-overlap).every((v, i) => v === current[i])) overlap--;
  return overlap ? { current, events: events.slice(overlap), reset: false } : { current, events: [], reset: true };
}
function parseJsonl(buffer) {
  const data = new TextDecoder('utf-8', { fatal: true }).decode(buffer);
  if (data && !data.endsWith('\n')) throw new Error('Incomplete JSONL snapshot');
  return data.split(/\r?\n/).filter(Boolean).map(line => {
    const event = JSON.parse(line);
    if (!event || typeof event !== 'object' || Array.isArray(event) || typeof event.type !== 'string') throw new Error('Invalid JSONL event');
    return event;
  });
}
function parseRcon(response) {
  const envelope = JSON.parse(response);
  if (envelope.schema !== 'telemetry-rcon/v1' || !Number.isFinite(envelope.tick) || !Array.isArray(envelope.events)) throw new Error('Invalid RCON envelope');
  if (envelope.error) throw new Error(`RCON export error: ${envelope.error}`);
  if (envelope.events.some(e => !e || typeof e !== 'object' || Array.isArray(e) || typeof e.type !== 'string')) throw new Error('Invalid RCON event');
  return envelope;
}
module.exports = { compare, parseJsonl, parseRcon };
