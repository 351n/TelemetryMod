import { readFile } from 'node:fs/promises';
import OBSWebSocket from 'obs-websocket-js';
import { createBridge } from './bridge.js';

try {
  const config = JSON.parse(await readFile(process.argv[2] ?? 'config.json', 'utf8'));
  const bridge = createBridge({ config, obs: new OBSWebSocket() });
  await bridge.start();
  console.info(`Listening for UDP telemetry on 127.0.0.1:${config.udpPort}`);
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { void bridge.stop().then(() => process.exit(0)).catch(error => { console.error(error.message); process.exit(1); }); });
} catch (error) {
  console.error(`Cannot start bridge: ${error.message}`);
  process.exitCode = 1;
}
