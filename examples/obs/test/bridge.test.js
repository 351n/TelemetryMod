import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import dgram from 'node:dgram';
import { readFile } from 'node:fs/promises';
import { createBridge, validateConfig } from '../src/bridge.js';

const template = JSON.parse(await readFile(new URL('../config.example.json', import.meta.url)));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
class FakeOBS extends EventEmitter {
  calls = [];
  attempts = 0;
  fail = false;
  async connect() { this.attempts++; if (this.fail) throw new Error('offline'); }
  async disconnect() { this.emit('ConnectionClosed'); }
  async call(name, args) {
    this.calls.push({ name, args });
    if (name === 'GetSceneItemId') return { sceneItemId: args.sourceName === 'Death alert' ? 1 : 2 };
    if (name === 'GetSceneItemEnabled') return { sceneItemEnabled: args.sceneItemId === 2 };
    return {};
  }
}
function send(socket, port, message) { return new Promise((resolve, reject) => socket.send(Buffer.from(message), port, '127.0.0.1', error => error ? reject(error) : resolve())); }

test('rejects invalid ports, remote OBS, bad thresholds and overlapping items', () => {
  const c = structuredClone(template);
  c.udpPort = 0; assert.throws(() => validateConfig(c));
  c.udpPort = 34199; c.obs.url = 'ws://example.com:4455'; assert.throws(() => validateConfig(c));
  c.obs.url = 'ws://localhost:4455'; c.actions.afk.enabled = true; c.actions.afk.returnSeconds = 300; assert.throws(() => validateConfig(c));
  c.actions.afk.enabled = false; c.actions.death.enabled = c.actions.research.enabled = true; c.actions.research.source = c.actions.death.source; assert.throws(() => validateConfig(c));
});

test('UDP events drive AFK transitions, extend alerts and restore prior visibility', async t => {
  const c = structuredClone(template); c.udpPort = 37971;
  c.actions.afk.enabled = c.actions.death.enabled = c.actions.research.enabled = true;
  c.actions.death.durationMs = 180; c.actions.research.durationMs = 70;
  const obs = new FakeOBS(), errors = [], client = dgram.createSocket('udp4');
  const bridge = createBridge({ config: c, obs, log: { info() {}, error(message) { errors.push(message); } }, reconnectMs: 30 });
  await bridge.start();
  t.after(async () => { client.close(); await bridge.stop(); });
  await sleep(30);
  const emit = event => send(client, c.udpPort, typeof event === 'string' ? event : JSON.stringify(event));
  await emit('{bad'); await emit({ type: 'other' });
  await emit({ type: 'afk', player: 'PlayerName', afk_seconds: 0 });
  await emit({ type: 'afk', player: 'PlayerName', afk_seconds: 301 });
  await emit({ type: 'afk', player: 'PlayerName', afk_seconds: 400 });
  await emit({ type: 'afk', player: 'PlayerName', afk_seconds: 0 });
  await emit({ type: 'death' }); await emit({ type: 'research' });
  await sleep(100); await emit({ type: 'death' });
  await sleep(110);
  assert.equal(obs.calls.filter(c => c.name === 'SetCurrentProgramScene').length, 2);
  assert.deepEqual(obs.calls.filter(c => c.name === 'SetCurrentProgramScene').map(c => c.args.sceneName), ['AFK', 'Game']);
  assert.equal(obs.calls.filter(c => c.name === 'SetSceneItemEnabled' && c.args.sceneItemId === 1).length, 1);
  assert.deepEqual(obs.calls.filter(c => c.name === 'SetSceneItemEnabled' && c.args.sceneItemId === 2).map(c => c.args.sceneItemEnabled), [true, true]);
  await sleep(110);
  assert.deepEqual(obs.calls.filter(c => c.name === 'SetSceneItemEnabled' && c.args.sceneItemId === 1).map(c => c.args.sceneItemEnabled), [true, false]);
  assert.equal(errors.length, 2);
});

test('reconnects and does not replay events received while disconnected', async t => {
  const c = structuredClone(template); c.udpPort = 37972; c.actions.death.enabled = true;
  const obs = new FakeOBS(), client = dgram.createSocket('udp4');
  const bridge = createBridge({ config: c, obs, log: { info() {}, error() {} }, reconnectMs: 40 });
  await bridge.start(); t.after(async () => { client.close(); await bridge.stop(); });
  await sleep(20); obs.fail = true; obs.emit('ConnectionClosed');
  await send(client, c.udpPort, JSON.stringify({ type: 'death' }));
  await sleep(60); obs.fail = false; await sleep(100);
  assert.ok(obs.attempts >= 3); assert.equal(obs.calls.length, 0);
});
