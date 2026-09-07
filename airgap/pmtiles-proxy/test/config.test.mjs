import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { loadConfig } from '../config.mjs';

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pmtiles-config-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const credentialsFile = path.join(dir, 'credentials.json');
  const manifestFile = path.join(dir, 'publication.json');
  fs.writeFileSync(credentialsFile, JSON.stringify({ accessKeyId: 'reader', secretAccessKey: 'test-only', sessionToken: 'token' }));
  const manifest = { schema_version: 1, release: '2026-07-22.0', themes: ['places'], objects: [
    { theme: 'places', filename: 'places.pmtiles', size: 200, uri: 's3://private-tiles/pmtiles/run/places.pmtiles' },
  ] };
  fs.writeFileSync(manifestFile, JSON.stringify(manifest));
  return { manifest, env: { PROXY_PUBLICATION_ID: 'israel-run', PROXY_S3_BUCKET: 'private-tiles', PROXY_S3_PREFIX: 'pmtiles/run',
    S3_ENDPOINT_URL: 'https://s3.internal', S3_REGION: 'us-east-1', PROXY_CREDENTIALS_FILE: credentialsFile, PROXY_MANIFEST_FILE: manifestFile } };
}

test('loads explicit credentials and manifest allowlist with path style by default', (t) => {
  const { env } = fixture(t);
  const config = loadConfig(env);
  assert.equal(config.forcePathStyle, true);
  assert.equal(config.credentials.accessKeyId, 'reader');
  assert.equal(config.credentials.sessionToken, 'token');
  assert.equal(config.objects.get('/pmtiles/israel-run/places.pmtiles').size, 200);
  assert.equal(config.origins.size, 0);
});

test('fails closed without dedicated credentials, irrespective of generator credentials', (t) => {
  const { env } = fixture(t);
  delete env.PROXY_CREDENTIALS_FILE;
  env.AWS_ACCESS_KEY_ID = 'generator'; env.AWS_SECRET_ACCESS_KEY = 'generator-secret';
  assert.throws(() => loadConfig(env), /PROXY_CREDENTIALS_FILE/);
});

test('rejects out-of-prefix objects and malformed publications', (t) => {
  const { env, manifest } = fixture(t);
  for (const uri of ['s3://other/pmtiles/run/places.pmtiles', 's3://private-tiles/elsewhere/places.pmtiles', 's3://private-tiles/pmtiles/run/../places.pmtiles']) {
    manifest.objects[0].uri = uri;
    fs.writeFileSync(env.PROXY_MANIFEST_FILE, JSON.stringify(manifest));
    assert.throws(() => loadConfig(env), /outside/);
  }
  manifest.themes = ['places', 'places'];
  fs.writeFileSync(env.PROXY_MANIFEST_FILE, JSON.stringify(manifest));
  assert.throws(() => loadConfig(env), /manifest/);
});

test('rejects path tricks, permissive origins and embedded endpoint credentials', (t) => {
  const { env } = fixture(t);
  for (const values of [{ PROXY_PUBLICATION_ID: '../private' }, { PROXY_S3_PREFIX: 'pmtiles/../secret' },
    { PROXY_S3_PREFIX: 'pmtiles/%2e%2e' }, { S3_ENDPOINT_URL: 'https://user:password@s3.internal' },
    { PROXY_CORS_ORIGINS: '*' }, { PROXY_S3_FORCE_PATH_STYLE: 'yes' }]) assert.throws(() => loadConfig({ ...env, ...values }));
});
