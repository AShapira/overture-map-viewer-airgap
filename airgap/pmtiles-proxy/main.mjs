import { loadConfig } from './config.mjs';
import { createStorage } from './s3.mjs';
import { createServer } from './server.mjs';

try {
  const config = loadConfig();
  const server = createServer(config, createStorage(config));
  server.on('error', () => { console.error('Proxy listener failed'); process.exitCode = 1; server.shutdown(); });
  server.listen(config.port, '0.0.0.0', () => console.log('PMTiles proxy listening'));
  process.once('SIGTERM', () => server.shutdown());
  process.once('SIGINT', () => server.shutdown());
} catch {
  // Configuration may contain credentials or private endpoint details.
  console.error('Proxy startup failed; check configuration, manifest, credentials and CA mounts');
  process.exitCode = 1;
}
