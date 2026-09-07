import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { once } from 'node:events';
import { createServer } from '../server.mjs';

const archive = Buffer.concat([Buffer.from('504d54696c657303', 'hex'), Buffer.alloc(16384, 42)]);
const route = '/pmtiles/israel-run/places.pmtiles';
async function fixture(t, request, options = {}) {
  const calls = [];
  const logs = [];
  const config = { objects: new Map([[route, { key: 'pmtiles/run/places.pmtiles', size: archive.length }]]), origins: new Set(['https://maps.internal']) };
  const storage = { async request(method, object, headers, signal) {
    calls.push({ method, headers, signal });
    if (request) return request(method, object, headers, signal);
    if (headers['if-match'] === '"old"') throw { $metadata: { httpStatusCode: 412 } };
    if (headers['if-none-match'] === '"version-1"') throw { $metadata: { httpStatusCode: 304 } };
    const [start, end] = headers.range ? headers.range.slice(6).split('-').map(Number) : [0, archive.length - 1];
    return { status: headers.range ? 206 : 200, length: end - start + 1,
      range: headers.range ? `bytes ${start}-${end}/${archive.length}` : undefined,
      etag: '"version-1"', modified: 'Mon, 07 Sep 2026 00:00:00 GMT',
      body: method === 'GET' ? Readable.from([archive.subarray(start, end + 1)]) : undefined };
  } };
  const server = createServer(config, storage, { log: (v) => logs.push(v), ...options });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${server.address().port}`;
  return { server, calls, logs, base, get: (init = {}, path = route) => fetch(base + path, init) };
}

test('full GET, HEAD and exact PMTiles header range', async (t) => {
  const { get, calls } = await fixture(t);
  const full = await get();
  assert.equal(full.status, 200);
  assert.deepEqual(Buffer.from(await full.arrayBuffer()), archive);
  const head = await get({ method: 'HEAD', headers: { Range: 'bytes=0-7' } });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('content-length'), String(archive.length));
  assert.equal((await head.arrayBuffer()).byteLength, 0);
  assert.equal(calls.at(-1).method, 'HEAD');
  assert.equal(calls.at(-1).headers.range, undefined);
  const ranged = await get({ headers: { Range: 'bytes=0-7' } });
  assert.equal(ranged.status, 206);
  assert.equal(ranged.headers.get('content-range'), `bytes 0-7/${archive.length}`);
  assert.equal(ranged.headers.get('content-length'), '8');
  assert.equal(ranged.headers.get('etag'), '"version-1"');
  assert.equal(ranged.headers.get('accept-ranges'), 'bytes');
  assert.equal(Buffer.from(await ranged.arrayBuffer()).toString('hex'), '504d54696c657303');
});

test('open-ended, suffix, clamped and invalid ranges', async (t) => {
  const { get } = await fixture(t);
  for (const [range, expected] of [['bytes=16380-', archive.subarray(16380)], ['bytes=-5', archive.subarray(-5)], ['bytes=0-999999', archive]]) {
    const res = await get({ headers: { Range: range } });
    assert.equal(res.status, 206);
    assert.deepEqual(Buffer.from(await res.arrayBuffer()), expected);
  }
  for (const range of ['bytes=999999-', 'bytes=-0']) {
    const res = await get({ headers: { Range: range } });
    assert.equal(res.status, 416);
    assert.equal(res.headers.get('content-range'), `bytes */${archive.length}`);
  }
  for (const range of ['bytes=3-1', 'bytes=-', 'bytes=0-1,3-4', 'items=0-5', 'bytes=999999999999999999-']) {
    assert.equal((await get({ headers: { Range: range } })).status, 400);
  }
});

test('conditional responses, CORS success and error headers', async (t) => {
  const { get } = await fixture(t);
  assert.equal((await get({ headers: { 'If-Match': '"old"' } })).status, 412);
  const unchanged = await get({ headers: { 'If-None-Match': '"version-1"' } });
  assert.equal(unchanged.status, 304);
  assert.equal(unchanged.headers.get('content-length'), null);
  const headers = { Origin: 'https://maps.internal', 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'Range, If-Match, If-None-Match' };
  const preflight = await get({ method: 'OPTIONS', headers });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('content-length'), null);
  assert.equal(preflight.headers.get('access-control-allow-origin'), headers.Origin);
  assert.match(preflight.headers.get('access-control-expose-headers'), /Content-Range/);
  assert.equal(preflight.headers.get('vary'), 'Origin');
  for (const change of [{ Origin: 'https://unapproved.internal' }, { 'Access-Control-Request-Headers': 'Authorization' }, { 'Access-Control-Request-Method': 'PUT' }]) {
    assert.equal((await get({ method: 'OPTIONS', headers: { ...headers, ...change } })).status, 403);
  }
  const error = await get({ headers: { Origin: headers.Origin, Range: 'bytes=999999-' } });
  assert.equal(error.headers.get('access-control-allow-origin'), headers.Origin);
  assert.equal(error.headers.get('cache-control'), 'no-store');
  const noOrigin = await get();
  assert.equal(noOrigin.headers.get('access-control-allow-origin'), null);
  await noOrigin.arrayBuffer();
});

test('unknown paths, queries and methods never reach storage', async (t) => {
  const { get, calls } = await fixture(t);
  for (const path of [route + '?bucket=secret', route.replace('places', 'buildings'), '/pmtiles/other/places.pmtiles', '/pmtiles/israel-run/%70laces.pmtiles', '/pmtiles/israel-run/%2e%2e/places.pmtiles']) {
    assert.equal((await get({}, path)).status, 404);
  }
  for (const method of ['POST', 'PUT', 'DELETE', 'PATCH']) assert.equal((await get({ method })).status, 405);
  assert.equal(calls.length, 0);
});

test('bad credentials, unavailable storage and upstream status errors are sanitized', async (t) => {
  for (const status of [403, 404, 500, 503]) {
    const { get } = await fixture(t, () => { throw { message: 'SECRET signed endpoint', $metadata: { httpStatusCode: status } }; });
    const res = await get();
    assert.equal(res.status, status === 404 ? 404 : 502);
    assert.equal(await res.text(), '');
    assert.equal((await get({}, '/readyz')).status, 503);
    assert.equal((await get({}, '/healthz')).status, 200);
  }
});

test('range violations and encoded archives fail before forwarding bytes', async (t) => {
  for (const upstream of [
    { status: 200, length: archive.length },
    { status: 206, length: 8, range: `bytes 1-8/${archive.length}` },
    { status: 206, length: 8, range: `bytes 0-7/${archive.length}`, encoding: 'gzip' },
  ]) {
    let consumed = false;
    const body = Readable.from((async function* () { consumed = true; yield archive; })());
    const { get } = await fixture(t, () => ({ ...upstream, body }));
    assert.equal((await get({ headers: { Range: 'bytes=0-7' } })).status, 502);
    assert.equal(body.destroyed, true);
    assert.equal(consumed, false);
  }
});

test('truncated upstream fails the stream', async (t) => {
  const { get } = await fixture(t, () => ({ status: 200, length: archive.length, body: Readable.from([archive.subarray(0, 10)]) }));
  await assert.rejects(async () => { const res = await get(); await res.arrayBuffer(); });
});

test('timeouts abort storage and return a bounded failure', async (t) => {
  let aborted = false;
  const { get } = await fixture(t, (method, object, headers, signal) => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => { aborted = true; reject(new Error('aborted')); }, { once: true });
  }), { idleMs: 50 });
  // A response socket idle timeout may close the socket before an HTTP error can be written.
  let res;
  try { res = await get(); } catch (error) { assert.equal(error.name, 'TypeError'); }
  if (res) assert.equal(res.status, 504);
  assert.equal(aborted, true);
});

test('client cancellation stops upstream; no whole-object buffering', async (t) => {
  let sent = 0;
  let aborted;
  const stopped = new Promise((resolve) => { aborted = resolve; });
  const { get } = await fixture(t, (method, object, headers, signal) => {
    signal.addEventListener('abort', aborted, { once: true });
    return { status: 200, length: archive.length, body: Readable.from((async function* () {
      while (sent < archive.length) { sent++; yield Buffer.alloc(1); await new Promise((resolve) => setTimeout(resolve, 1)); }
    })()) };
  });
  const controller = new AbortController();
  const res = await get({ signal: controller.signal });
  const reader = res.body.getReader();
  await reader.read();
  controller.abort();
  await Promise.race([stopped, new Promise((_, reject) => setTimeout(() => reject(new Error('Not cancelled')), 1000).unref())]);
  assert.ok(sent < archive.length / 2);
});

test('readiness detects object size mismatch; concurrency is bounded', async (t) => {
  const bad = await fixture(t, () => ({ status: 200, length: 0 }));
  assert.equal((await bad.get({}, '/readyz')).status, 503);
  const limited = await fixture(t, undefined, { maxActive: 0 });
  assert.equal((await limited.get()).status, 503);
  assert.equal(limited.calls.length, 0);
});
