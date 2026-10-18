import test from 'node:test';
import assert from 'node:assert/strict';
import { RateLimiter, cleanUtm, clip, hashKey, statusFor } from './core.js';

test('hashKey is sha-256 hex', () => assert.equal(hashKey('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'));
test('SQLSTATE maps to HTTP', () => {
  assert.deepEqual(['42501', 'P0002', '22023', '23514', '23505', 'XX000', '23P01', 'P0001', '54000'].map(statusFor), [403, 404, 422, 422, 409, 500, 409, 409, 422]);
});
test('rate limiter blocks then resets', () => {
  const r = new RateLimiter(2, 1000);
  assert.ok(r.allow('a', 0)); assert.ok(r.allow('a', 1)); assert.ok(!r.allow('a', 2)); assert.ok(r.allow('a', 1500));
});
test('clip trims and bounds; utm keeps only known keys', () => {
  assert.equal(clip('  hi  ', 10), 'hi'); assert.equal(clip('abcdef', 3), 'abc'); assert.equal(clip(5, 3), null); assert.equal(clip('  ', 3), null);
  assert.deepEqual(cleanUtm({ utm_source: 'x', evil: 'y' }), { utm_source: 'x' });
});
