// Isolated private-S3 acceptance. Default engine: Podman. The CI image job may
// supply its existing engine through CONTAINER_ENGINE; no production state is touched.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { createRequire } from 'node:module';
import { S3Client, CreateBucketCommand, PutObjectCommand, GetObjectCommand, HeadObjectCommand, ListObjectsV2Command, DeleteObjectCommand } from '@aws-sdk/client-s3';
import { tinyArchive } from './fixture.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const engine = process.env.CONTAINER_ENGINE ?? 'podman';
const minioImage = 'docker.io/minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e';
const mcImage = 'docker.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727';
const proxyImage = process.env.PROXY_IMAGE ?? 'localhost/overture-pmtiles-proxy-airgap:dev';
const viewerImage = process.env.VIEWER_IMAGE ?? 'localhost/overture-explorer-airgap:local';
const work = fs.mkdtempSync(path.join(process.env.PROXY_TEST_WORK_ROOT ?? os.tmpdir(), 'pmtiles-private-'));
const name = `pmtiles-private-${randomBytes(6).toString('hex')}`;
const containers = [];
const adminPassword = randomBytes(24).toString('hex');
const readerPassword = randomBytes(24).toString('hex');
let admin, reader, browser;
let networkCreated = false;
const evidence = { platform: process.platform, engine, checks: [] };
function run(args, options = {}) {
  const result = spawnSync(engine, args, { encoding: 'utf8', timeout: 120000, ...options });
  if (result.status !== 0) throw new Error(`Container operation failed (${args[0]}): ${(result.stderr ?? '').replaceAll(adminPassword, '[redacted]').replaceAll(readerPassword, '[redacted]')}`);
  return result.stdout.trim();
}
// An explicit machine address supports sites where Windows localhost forwarding is unavailable.
const testHost = process.env.PROXY_TEST_HOST ?? '127.0.0.1';
const publishHost = testHost === '127.0.0.1' ? '127.0.0.1' : '0.0.0.0';
const mount = (source, target) => ['--mount', `type=bind,source=${source},target=${target},readonly`];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function wait(url) {
  for (let i = 0; i < 60; i++) {
    try { if ((await fetch(url, { signal: AbortSignal.timeout(1000) })).ok) return; } catch { /* startup */ }
    await sleep(500);
  }
  throw new Error('Service readiness timed out: ' + url);
}
function start(suffix, args) {
  const container = `${name}-${suffix}`;
  run(['run', '-d', '--pull=never', '--name', container, '--network', name, ...args]);
  containers.push(container);
  return container;
}
const port = (container, target) => Number(run(['port', container, `${target}/tcp`]).split('\n')[0].split(':').at(-1));
function record(check) { evidence.checks.push(check); console.log(check); }

try {
  for (const image of [minioImage, mcImage, proxyImage, viewerImage]) run(['image', 'inspect', image]);
  run(['network', 'create', name]); networkCreated = true;
  const minio = start('s3', ['--network-alias', 'private-s3', '-p', `${publishHost}::9000`, '-e', 'MINIO_ROOT_USER=fixtureadmin', '-e', `MINIO_ROOT_PASSWORD=${adminPassword}`, minioImage, 'server', '/data']);
  const endpoint = `http://${testHost}:${port(minio, 9000)}`;
  await wait(endpoint + '/minio/health/live');
  const clientOptions = { endpoint, region: 'us-east-1', forcePathStyle: true, maxAttempts: 1 };
  admin = new S3Client({ ...clientOptions, credentials: { accessKeyId: 'fixtureadmin', secretAccessKey: adminPassword } });
  reader = new S3Client({ ...clientOptions, credentials: { accessKeyId: 'fixturereader', secretAccessKey: readerPassword } });
  await admin.send(new CreateBucketCommand({ Bucket: 'private-tiles' }));
  const sourceDir = process.env.PROXY_TEST_TILES_DIR;
  const themes = sourceDir ? ['base', 'buildings', 'places', 'divisions', 'transportation', 'addresses'] : ['places'];
  const fixture = tinyArchive();
  const objects = [];
  let bbox;
  for (const theme of themes) {
    const key = `publication/${theme}.pmtiles`;
    const file = sourceDir && path.join(sourceDir, `${theme}.pmtiles`);
    const size = file ? fs.statSync(file).size : fixture.length;
    const header = Buffer.alloc(127);
    if (file) {
      const fd = fs.openSync(file, 'r');
      try { assert.equal(fs.readSync(fd, header, 0, 127, 0), 127); } finally { fs.closeSync(fd); }
    } else fixture.copy(header, 0, 0, 127);
    assert.equal(header.subarray(0, 8).toString('hex'), '504d54696c657303');
    const bounds = [102, 106, 110, 114].map((offset) => header.readInt32LE(offset) / 1e7);
    if (bbox) assert.deepEqual(bounds, bbox, 'Test archives must belong to the same regional publication');
    else bbox = bounds;
    await admin.send(new PutObjectCommand({ Bucket: 'private-tiles', Key: key, Body: file ? fs.createReadStream(file) : fixture, ContentLength: size, ContentType: 'application/vnd.pmtiles' }));
    objects.push({ theme, filename: `${theme}.pmtiles`, uri: `s3://private-tiles/${key}`, size });
  }
  await admin.send(new PutObjectCommand({ Bucket: 'private-tiles', Key: 'outside/secret.pmtiles', Body: fixture }));
  const policy = { Version: '2012-10-17', Statement: [{ Effect: 'Allow', Action: ['s3:GetObject'], Resource: ['arn:aws:s3:::private-tiles/publication/*'] }] };
  fs.writeFileSync(path.join(work, 'policy.json'), JSON.stringify(policy));
  run(['run', '--rm', '--pull=never', '--network', name, ...mount(work, '/fixture'), '--entrypoint', '/bin/sh',
    '-e', `ADMIN_PASSWORD=${adminPassword}`, '-e', `READER_PASSWORD=${readerPassword}`, mcImage, '-ec',
    'mc alias set fixture http://private-s3:9000 fixtureadmin "$ADMIN_PASSWORD" >/dev/null; mc admin user add fixture fixturereader "$READER_PASSWORD" >/dev/null; mc admin policy create fixture pmtiles-reader /fixture/policy.json >/dev/null; mc admin policy attach fixture pmtiles-reader --user fixturereader >/dev/null']);
  const direct = await fetch(endpoint + '/private-tiles/publication/places.pmtiles', { headers: { Range: 'bytes=0-7' } });
  assert.equal(direct.status, 403);
  await direct.arrayBuffer();
  for (const command of [new ListObjectsV2Command({ Bucket: 'private-tiles' }),
    new PutObjectCommand({ Bucket: 'private-tiles', Key: 'publication/write.pmtiles', Body: fixture }),
    new DeleteObjectCommand({ Bucket: 'private-tiles', Key: 'publication/places.pmtiles' }),
    new GetObjectCommand({ Bucket: 'private-tiles', Key: 'outside/secret.pmtiles' })]) {
    await assert.rejects(reader.send(command), (error) => error.$metadata?.httpStatusCode === 403);
  }
  record('Private bucket denies anonymous reads; reader cannot list, write, delete or read outside prefix');
  fs.mkdirSync(path.join(work, 'config'));
  fs.mkdirSync(path.join(work, 'data'));
  const manifest = { schema_version: 1, release: 'proxy-test', themes, bbox, objects };
  evidence.publication = { themes, bbox };
  fs.writeFileSync(path.join(work, 'publication.json'), JSON.stringify(manifest));
  fs.writeFileSync(path.join(work, 'credentials.json'), JSON.stringify({ accessKeyId: 'fixturereader', secretAccessKey: readerPassword }), { mode: 0o644 });
  const catalog = spawnSync(process.execPath, [path.join(root, 'scripts/generate-airgap-catalog.mjs'), '--release', 'proxy-test',
    '--publication-manifest', path.join(work, 'publication.json'), '--data-dir', path.join(work, 'data'), '--out-dir', path.join(work, 'catalog'), '--tile-base', '/pmtiles/private-test/'], { encoding: 'utf8' });
  assert.equal(catalog.status, 0, catalog.stderr);
  fs.writeFileSync(path.join(work, 'config/viewer-config.json'), JSON.stringify({ stacCatalogUrl: '/catalog/catalog.json', releaseId: 'proxy-test',
    downloadBaseUrl: '/data/', geocoderBaseUrl: null, features: { search: false, download: false, externalDocs: false } }));
  const proxy = start('proxy', ['--network-alias', 'pmtiles-proxy', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true', '--memory', '512m',
    ...mount(path.join(work, 'credentials.json'), '/run/proxy/credentials.json'), ...mount(path.join(work, 'publication.json'), '/run/proxy/publication.json'),
    '-e', 'PROXY_CREDENTIALS_FILE=/run/proxy/credentials.json', '-e', 'PROXY_MANIFEST_FILE=/run/proxy/publication.json',
    '-e', 'PROXY_PUBLICATION_ID=private-test', '-e', 'PROXY_S3_BUCKET=private-tiles', '-e', 'PROXY_S3_PREFIX=publication',
    '-e', 'S3_ENDPOINT_URL=http://private-s3:9000', '-e', 'S3_REGION=us-east-1', '-e', 'PROXY_CORS_ORIGINS=https://maps.internal', proxyImage]);
  const initialDiff = run(['diff', proxy]); // Engines may create /etc mount targets at container creation.
  // Viewer uses only read-only public catalog/config mounts; credentials are never in its tree.
  const viewer = start('viewer', ['-p', `${publishHost}::8080`, '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
    '--tmpfs', '/tmp', '--tmpfs', '/var/cache/nginx', '--tmpfs', '/var/run',
    ...mount(path.join(root, 'airgap/nginx/default.conf'), '/etc/nginx/conf.d/default.conf'),
    ...mount(path.join(root, 'airgap/nginx/pmtiles-proxy.conf'), '/etc/nginx/pmtiles-proxy/routes.conf'),
    ...mount(path.join(work, 'catalog'), '/usr/share/nginx/html/catalog'), ...mount(path.join(work, 'config'), '/usr/share/nginx/html/config'), viewerImage]);
  const base = `http://${testHost}:${port(viewer, 8080)}`;
  await wait(base);
  run(['exec', proxy, 'node', '-e', "fetch('http://127.0.0.1:8080/readyz').then(r=>process.exit(r.ok?0:1))"]);
  const tileUrl = base + '/pmtiles/private-test/places.pmtiles';
  const range = await fetch(tileUrl, { headers: { Range: 'bytes=0-7' } });
  assert.equal(range.status, 206);
  assert.equal(Buffer.from(await range.arrayBuffer()).toString('hex'), '504d54696c657303');
  const size = objects.find((o) => o.theme === 'places').size;
  assert.equal(range.headers.get('content-range'), `bytes 0-7/${size}`);
  const head = await fetch(tileUrl, { method: 'HEAD' });
  assert.equal(head.status, 200); assert.equal(head.headers.get('content-length'), String(size));
  assert.equal((await head.arrayBuffer()).byteLength, 0);
  assert.equal((await fetch(tileUrl, { headers: { 'If-Match': '"wrong"' } })).status, 412);
  assert.equal((await fetch(tileUrl, { headers: { 'If-None-Match': head.headers.get('etag') } })).status, 304);
  assert.equal((await fetch(tileUrl, { headers: { 'If-None-Match': head.headers.get('etag') } })).headers.get('content-length'), null);
  const eof = await fetch(tileUrl, { headers: { Range: `bytes=${size}-`, Origin: 'https://maps.internal' } });
  assert.equal(eof.status, 416); assert.equal(eof.headers.get('content-range'), `bytes */${size}`);
  assert.equal(eof.headers.get('access-control-allow-origin'), 'https://maps.internal');
  const options = await fetch(tileUrl, { method: 'OPTIONS', headers: { Origin: 'https://maps.internal', 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'range,if-match' } });
  assert.equal(options.status, 204);
  if (!sourceDir) {
    const full = await fetch(tileUrl);
    assert.equal(full.status, 200); assert.deepEqual(Buffer.from(await full.arrayBuffer()), fixture);
  }
  for (const theme of themes) {
    const res = await fetch(base + `/pmtiles/private-test/${theme}.pmtiles`, { headers: { Range: 'bytes=0-7' } });
    assert.equal(res.status, 206); assert.equal(Buffer.from(await res.arrayBuffer()).toString('hex'), '504d54696c657303');
  }
  record(`NGINX → signed proxy → private S3: HEAD, ranges, conditions, CORS and ${themes.length} theme signatures passed`);
  const require = createRequire(path.join(root, 'package.json'));
  const { chromium } = require('playwright');
  browser = await chromium.launch({ headless: true, ...(process.env.PROXY_TEST_BROWSER_EXECUTABLE ? { executablePath: process.env.PROXY_TEST_BROWSER_EXECUTABLE } : {}) });
  const page = await browser.newPage();
  const external = [], errors = [], responses = [];
  page.on('request', (req) => { const url = new URL(req.url()); if (!['data:', 'blob:'].includes(url.protocol) && url.origin !== base) external.push(req.url()); });
  page.on('pageerror', (error) => errors.push(error.message));

  page.on('response', (res) => { if (res.url().includes('/pmtiles/')) responses.push(res.status()); });
  await page.addInitScript(({ origin }) => localStorage.setItem('overture-stac-cache', JSON.stringify({
    releaseUrl: `${origin}/catalog/proxy-test/catalog.json`, releaseId: 'proxy-test', pmtilesUrls: { places: 'https://old-gateway.invalid/places.pmtiles' },
  })), { origin: base });
  await page.goto(base + (sourceDir ? '/#14/32.0728/34.7909' : '/#1/0/0'), { waitUntil: 'load' });
  await page.waitForFunction(() => window.map?.getSource('places'), null, { timeout: 30000 });
  await page.waitForTimeout(2000);
  if (!sourceDir) await page.evaluate(() => {
    window.map.setProjection({ type: 'mercator' });
    window.map.jumpTo({ center: [0, 0], zoom: 1 });
    window.map.addLayer({ id: 'proxy-test-point', type: 'circle', source: 'places', 'source-layer': 'place', paint: { 'circle-radius': 10, 'circle-color': '#f00' } });
  });
  try {
    await page.waitForFunction(() => window.map.queryRenderedFeatures().length > 0, null, { timeout: 10000 });
  } catch (error) {
    await page.screenshot({ path: path.join(work, 'failure.png') });
    console.error('Browser failure evidence: ' + work);
    console.error(JSON.stringify({ responses, errors, external, map: await page.evaluate(() => ({
      source: window.map.getSource('places').serialize(), features: window.map.querySourceFeatures('places', { sourceLayer: 'place' }).length,
      layer: window.map.getStyle().layers.find((layer) => layer.id === 'proxy-test-point')?.id, loaded: window.map.isSourceLoaded('places'), zoom: window.map.getZoom(),
    })) }));
    throw error;
  }
  assert.equal(external.length, 0, JSON.stringify(external));
  assert.equal(errors.length, 0, JSON.stringify(errors));
  assert.ok(responses.length > 0 && responses.every((v) => v === 206), JSON.stringify(responses));
  evidence.browser = { renderedFeatures: await page.evaluate(() => window.map.queryRenderedFeatures().length), rangeResponses: responses.length, externalRequests: external.length, pageErrors: errors.length };
  await page.screenshot({ path: path.join(work, 'viewer.png') });
  record('Browser rendered features through the proxy and replaced stale gateway URLs without external requests');
  await browser.close(); browser = undefined;
  // Real PMTiles client also parses the tiny archive and its directory through HTTP.
  const { PMTiles } = require('pmtiles');
  if (!sourceDir) assert.ok((await new PMTiles(tileUrl).getZxy(0, 0, 0)).data.byteLength > 0);
  const changes = run(['diff', proxy]);
  assert.equal(changes, initialDiff, 'Proxy filesystem changed after startup');
  evidence.proxyMemory = run(['stats', '--no-stream', '--format', '{{.MemUsage}}', proxy]);
  record('Proxy container filesystem remained unchanged');
  fs.writeFileSync(path.join(work, 'proxy.log'), run(['logs', proxy]));
  fs.writeFileSync(path.join(work, 'evidence.json'), JSON.stringify(evidence, null, 2));
  console.log(`Evidence: ${work}`);
} catch (error) {
  // Retain startup diagnostics from this invocation before removing its containers.
  for (const container of containers) {
    const output = spawnSync(engine, ['logs', container], { encoding: 'utf8', timeout: 5000 });
    fs.writeFileSync(path.join(work, `${container}.log`), ((output.stdout ?? '') + (output.stderr ?? '')).replaceAll(adminPassword, '[redacted]').replaceAll(readerPassword, '[redacted]'));
  }
  console.error(`Failure evidence: ${work}`);
  throw error;
} finally {
  await browser?.close();
  admin?.destroy(); reader?.destroy();
  for (const container of containers.reverse()) {
    // Only unique containers created by this invocation are removed.
    spawnSync(engine, ['rm', '-f', container], { stdio: 'ignore', timeout: 30000 });
  }
  if (networkCreated) spawnSync(engine, ['network', 'rm', name], { stdio: 'ignore', timeout: 30000 });
  fs.rmSync(path.join(work, 'credentials.json'), { force: true });
}
