import http from 'node:http';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const methods = 'GET, HEAD, OPTIONS';
const allowedHeaders = ['range', 'if-match', 'if-none-match'];
const exposedHeaders = 'ETag, Content-Range, Content-Length, Accept-Ranges, Last-Modified';

// Resolve ranges against the immutable publication size without an extra S3 HEAD per tile.
export function parseRange(value, size) {
  if (value === undefined) return undefined;
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!match || (!match[1] && !match[2])) throw Object.assign(new Error(), { status: 400 });
  const first = match[1] ? Number(match[1]) : undefined;
  const last = match[2] ? Number(match[2]) : undefined;
  if ([first, last].some((v) => v !== undefined && !Number.isSafeInteger(v)) ||
      (first !== undefined && last !== undefined && first > last)) throw Object.assign(new Error(), { status: 400 });
  if (first >= size || (first === undefined && last === 0)) throw Object.assign(new Error(), { status: 416 });
  const start = first ?? Math.max(0, size - last);
  const end = first === undefined ? size - 1 : Math.min(last ?? size - 1, size - 1);
  return { header: `bytes=${start}-${end}`, contentRange: `bytes ${start}-${end}/${size}`, length: end - start + 1 };
}

export function createServer(config, storage, { log = (entry) => console.log(JSON.stringify(entry)), idleMs = 60000, maxActive = 64 } = {}) {
  let active = 0;
  let closing = false;
  const controllers = new Set();
  function reply(res, status) {
    const bodyless = status === 204 || status === 304;
    if (bodyless) res.removeHeader('Content-Length');
    res.writeHead(status, { 'Cache-Control': 'no-store', ...(bodyless ? {} : { 'Content-Length': '0' }) });
    res.end();
  }
  const server = http.createServer({ maxHeaderSize: 16384 }, async (req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    if (req.url === '/healthz' || req.url === '/readyz') {
      if (!['GET', 'HEAD'].includes(req.method)) { res.setHeader('Allow', 'GET, HEAD'); return reply(res, 405); }
      if (closing) return reply(res, 503);
      if (req.url === '/healthz') return reply(res, 200);
      try {
        const signal = AbortSignal.timeout(5000);
        await Promise.all([...config.objects.values()].map(async (object) => {
          const metadata = await storage.request('HEAD', object, {}, signal);
          if (metadata.status !== 200 || metadata.length !== object.size || (metadata.encoding && metadata.encoding !== 'identity')) throw new Error();
        }));
        reply(res, 200);
      } catch { reply(res, 503); }
      return;
    }
    res.setHeader('Vary', 'Origin');
    const originAllowed = config.origins.has(req.headers.origin);
    if (originAllowed) {
      res.setHeader('Access-Control-Allow-Origin', req.headers.origin);
      res.setHeader('Access-Control-Expose-Headers', exposedHeaders);
    }
    const object = config.objects.get(req.url); // Exact raw path: no decoding, traversal, query strings, or URL forwarding.
    if (!object) return reply(res, 404);
    if (!['GET', 'HEAD', 'OPTIONS'].includes(req.method)) { res.setHeader('Allow', methods); return reply(res, 405); }
    if (req.method === 'OPTIONS') {
      const requested = (req.headers['access-control-request-headers'] ?? '').toLowerCase().split(',').map((v) => v.trim()).filter(Boolean);
      if (!originAllowed || !['GET', 'HEAD'].includes(req.headers['access-control-request-method']) || requested.some((v) => !allowedHeaders.includes(v))) return reply(res, 403);
      res.setHeader('Access-Control-Allow-Methods', methods);
      res.setHeader('Access-Control-Allow-Headers', allowedHeaders.join(', '));
      res.setHeader('Access-Control-Max-Age', '300');
      return reply(res, 204);
    }
    if (closing || active >= maxActive) return reply(res, 503);
    const controller = new AbortController();
    controllers.add(controller);
    active++;
    const started = performance.now();
    let bytes = 0;
    let outcome = 'complete';
    let body;
    const disconnect = () => { if (!res.writableFinished) controller.abort(); };
    res.on('close', disconnect);
    res.setTimeout(idleMs, () => { controller.abort(); res.destroy(); });
    const timeout = setTimeout(() => controller.abort(), idleMs);
    timeout.unref();
    try {
      const range = req.method === 'GET' ? parseRange(req.headers.range, object.size) : undefined;
      const headers = { 'if-match': req.headers['if-match'], 'if-none-match': req.headers['if-none-match'] };
      if (range) headers.range = range.header;
      const upstream = await storage.request(req.method, object, headers, controller.signal);
      body = upstream.body;
      clearTimeout(timeout);
      const expectedLength = range?.length ?? object.size;
      if (upstream.status !== (range ? 206 : 200) || upstream.length !== expectedLength ||
          (range && upstream.range !== range.contentRange) || (upstream.encoding && upstream.encoding !== 'identity')) {
        throw Object.assign(new Error(), { status: 502 });
      }
      res.setHeader('Content-Type', 'application/vnd.pmtiles');
      res.setHeader('Content-Length', expectedLength);
      res.setHeader('Accept-Ranges', 'bytes');
      res.setHeader('Cache-Control', 'private, max-age=3600');
      if (upstream.etag) res.setHeader('ETag', upstream.etag);
      if (upstream.modified) res.setHeader('Last-Modified', upstream.modified);
      if (range) res.setHeader('Content-Range', range.contentRange);
      res.statusCode = range ? 206 : 200;
      if (req.method === 'HEAD') res.end();
      else {
        const count = new Transform({
          transform(chunk, encoding, done) {
            bytes += chunk.length;
            done(bytes > expectedLength ? new Error('Upstream length mismatch') : null, chunk);
          },
          flush(done) { done(bytes === expectedLength ? null : new Error('Truncated upstream')); },
        });
        await pipeline(body, count, res, { signal: controller.signal });
      }
    } catch (error) {
      outcome = controller.signal.aborted ? 'aborted' : 'failed';
      body?.destroy();
      if (!res.headersSent && !res.destroyed) {
        // Never expose SDK messages, signed URLs, or S3 error payloads.
        const status = error.status ?? error.$metadata?.httpStatusCode;
        const safe = [304, 400, 404, 412, 416].includes(status) ? status : controller.signal.aborted ? 504 : 502;
        for (const header of ['Content-Range', 'Content-Type', 'ETag', 'Last-Modified', 'Accept-Ranges']) res.removeHeader(header);
        if (safe === 416) res.setHeader('Content-Range', `bytes */${object.size}`);
        reply(res, safe);
      } else res.destroy();
    } finally {
      clearTimeout(timeout);
      res.off('close', disconnect);
      controller.abort();
      body?.destroy();
      controllers.delete(controller);
      active--;
      log({ method: req.method, path: req.url, status: res.statusCode, bytes, outcome, durationMs: Math.round(performance.now() - started) });
    }
  });
  server.headersTimeout = 15000;
  server.requestTimeout = 30000;
  server.keepAliveTimeout = 5000;
  server.shutdown = () => {
    closing = true;
    server.close(() => storage.close?.());
    const deadline = setTimeout(() => {
      for (const controller of controllers) controller.abort();
      server.closeAllConnections();
      storage.close?.();
    }, 10000);
    deadline.unref();
    server.once('close', () => clearTimeout(deadline));
  };
  return server;
}
