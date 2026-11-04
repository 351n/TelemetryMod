import dgram from 'node:dgram';

export function validateConfig(config) {
  if (!config || typeof config !== 'object') throw new Error('Configuration must be an object');
  if (!Number.isInteger(config.udpPort) || config.udpPort < 1 || config.udpPort > 65535) throw new Error('udpPort must be 1–65535');
  let url;
  try { url = new URL(config.obs?.url); } catch { throw new Error('obs.url must be a WebSocket URL'); }
  if (!['ws:', 'wss:'].includes(url.protocol) || !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) throw new Error('obs.url must point to localhost');
  if (typeof config.obs.password !== 'string') throw new Error('obs.password must be a string');
  if (!config.actions || typeof config.actions !== 'object') throw new Error('actions is required');
  for (const name of ['afk', 'death', 'research']) {
    const action = config.actions[name];
    if (!action || typeof action.enabled !== 'boolean') throw new Error(`${name}.enabled must be a boolean`);
    if (!action.enabled) continue;
    const fields = name === 'afk' ? ['player', 'scene', 'returnScene'] : ['scene', 'source'];
    for (const field of fields) if (typeof action[field] !== 'string' || !action[field].trim()) throw new Error(`${name}.${field} is required`);
    if (name === 'afk') {
      if (!Number.isFinite(action.thresholdSeconds) || !Number.isFinite(action.returnSeconds) || action.returnSeconds < 0 || action.thresholdSeconds <= action.returnSeconds) throw new Error('AFK thresholds must satisfy thresholdSeconds > returnSeconds >= 0');
    } else if (!Number.isInteger(action.durationMs) || action.durationMs < 1 || action.durationMs > 2147483647) throw new Error(`${name}.durationMs must be a positive timer duration`);
  }
  const { death, research } = config.actions;
  if (death.enabled && research.enabled && death.scene === research.scene && death.source === research.source) throw new Error('Death and research must use different scene items');
  return config;
}

export function createBridge({ config, obs, log = console, reconnectMs = 2000 }) {
  validateConfig(config);
  let connected = false, stopped = false, reconnectTimer, afkState = null, queue = Promise.resolve(), connectionEpoch = 0;
  const alerts = new Map();
  const socket = dgram.createSocket('udp4');
  function enqueue(fn) {
    queue = queue.then(fn).catch(error => log.error(`OBS action failed: ${error.message}`));
    return queue;
  }
  function clearAlerts() {
    for (const alert of alerts.values()) clearTimeout(alert.timer);
    alerts.clear();
  }
  function disconnected() {
    connected = false;
    connectionEpoch++;
    afkState = null;
    clearAlerts();
    scheduleReconnect();
  }
  function scheduleReconnect() {
    if (!stopped && !reconnectTimer) reconnectTimer = setTimeout(() => { reconnectTimer = null; void connect(); }, reconnectMs);
  }
  async function connect() {
    if (stopped || connected) return;
    try {
      await obs.connect(config.obs.url, config.obs.password);
      if (stopped) { await obs.disconnect(); return; }
      connected = true;
      log.info('Connected to OBS');
    } catch (error) {
      log.error(`OBS connection failed: ${error.message}`);
      scheduleReconnect();
    }
  }
  obs.on('ConnectionClosed', disconnected);
  obs.on('error', error => log.error(`OBS connection error: ${error.message}`));
  async function showAlert(kind, action) {
    let state = alerts.get(kind);
    if (state) {
      clearTimeout(state.timer);
    } else {
      const { sceneItemId } = await obs.call('GetSceneItemId', { sceneName: action.scene, sourceName: action.source });
      const { sceneItemEnabled } = await obs.call('GetSceneItemEnabled', { sceneName: action.scene, sceneItemId });
      await obs.call('SetSceneItemEnabled', { sceneName: action.scene, sceneItemId, sceneItemEnabled: true });
      state = { sceneItemId, original: sceneItemEnabled };
      alerts.set(kind, state);
    }
    const generation = (state.generation ?? 0) + 1;
    state.generation = generation;
    state.timer = setTimeout(() => void enqueue(async () => {
      if (alerts.get(kind) !== state || state.generation !== generation || !connected) return;
      alerts.delete(kind);
      await obs.call('SetSceneItemEnabled', { sceneName: action.scene, sceneItemId: state.sceneItemId, sceneItemEnabled: state.original });
    }), action.durationMs);
  }
  function accept(data) {
    let event;
    try { event = JSON.parse(data.toString('utf8')); } catch { log.error('Invalid JSON datagram'); return; }
    if (!event || typeof event !== 'object' || Array.isArray(event) || !['afk', 'death', 'research'].includes(event.type)) { log.error('Unknown or invalid telemetry event'); return; }
    if (!connected) return;
    const epoch = connectionEpoch;
    const action = config.actions[event.type];
    if (!action.enabled) return;
    if (event.type === 'afk') {
      if (event.player !== action.player || !Number.isFinite(event.afk_seconds) || event.afk_seconds < 0) return;
      const current = event.afk_seconds >= action.thresholdSeconds ? true : event.afk_seconds <= action.returnSeconds ? false : afkState;
      if (afkState === null) { afkState = current; return; }
      if (current === null || current === afkState) return;
      afkState = current;
      const sceneName = current ? action.scene : action.returnScene;
      void enqueue(async () => { if (connected && epoch === connectionEpoch) await obs.call('SetCurrentProgramScene', { sceneName }); });
    } else {
      void enqueue(async () => { if (connected && epoch === connectionEpoch) await showAlert(event.type, action); });
    }
  }
  socket.on('message', accept);
  socket.on('error', error => log.error(`UDP error: ${error.message}`));
  return {
    async start() {
      await new Promise((resolve, reject) => { socket.once('error', reject); socket.bind(config.udpPort, '127.0.0.1', () => { socket.off('error', reject); resolve(); }); });
      void connect();
    },
    async stop() {
      stopped = true;
      clearTimeout(reconnectTimer);
      clearAlerts();
      await queue;
      await new Promise(resolve => socket.close(resolve));
      if (connected) await obs.disconnect();
      connected = false;
    },
    address() { return socket.address(); }
  };
}
