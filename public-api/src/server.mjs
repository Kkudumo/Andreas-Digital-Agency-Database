// A plain Node HTTP server around handle(). Run it anywhere Node runs (a VM, a container, Fly, Render); on Vercel use api/index.mjs.
import http from 'node:http';
import { handle, createLimiter, MAX_BODY_BYTES } from './api.mjs';
import { call } from './db.mjs';

export function createServer({ callFn = call, perKeyPerMinute = 600, perIpPerMinute = 120, trustProxy = process.env.ADA_PUBLIC_API_TRUST_PROXY === 'on' } = {}) {
  const limiter = createLimiter({ perMinute: perKeyPerMinute });
  const ipLimiter = createLimiter({ perMinute: perIpPerMinute });
  return http.createServer((req, res) => {
    const chunks = []; let size = 0; let tooBig = false;
    req.on('data', (c) => { size += c.length; if (size > MAX_BODY_BYTES) { tooBig = true; } else chunks.push(c); });
    req.on('end', async () => {
      const ip = (trustProxy && String(req.headers['x-forwarded-for'] ?? '').split(',')[0].trim()) || req.socket.remoteAddress;
      let out;
      if (req.url === '/healthz') out = { status: 200, headers: { 'content-type': 'text/plain' }, body: 'ok' };
      else if (tooBig) out = { status: 413, headers: { 'content-type': 'application/json' }, body: '{"error":"request too large"}' };
      else out = await handle({ method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(chunks).toString('utf8'), ip }, { call: callFn, limiter, ipLimiter, log: (...a) => console.error(...a) });
      res.writeHead(out.status, out.headers); res.end(out.body);
    });
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT ?? 8787);
  createServer().listen(port, () => console.log(`ADA public API listening on :${port}`));
}
