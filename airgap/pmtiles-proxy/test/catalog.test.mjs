import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const generator = fileURLToPath(new URL('../../../scripts/generate-airgap-catalog.mjs', import.meta.url));

test('catalog revision changes with gateway or publication and remains stable otherwise', (t) => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'proxy-catalog-'));
  t.after(() => fs.rmSync(work, { recursive: true, force: true }));
  const manifest = { schema_version: 1, release: 'same-release', bbox: [34.2, 29.4, 35.9, 33.4], themes: ['places'], objects: [
    { theme: 'places', filename: 'places.pmtiles', uri: 's3://private-tiles/run-1/places.pmtiles', size: 123 },
  ] };
  function generate(tileBase) {
    fs.writeFileSync(path.join(work, 'manifest.json'), JSON.stringify(manifest));
    const result = spawnSync(process.execPath, [generator, '--release', manifest.release, '--publication-manifest', path.join(work, 'manifest.json'),
      '--data-dir', path.join(work, 'data'), '--out-dir', path.join(work, 'catalog'), '--tile-base', tileBase], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const root = JSON.parse(fs.readFileSync(path.join(work, 'catalog/catalog.json')));
    return root.links.find((link) => link.latest).href;
  }
  const old = generate('https://gateway.internal/run-1/');
  const proxy = generate('/pmtiles/run-1/');
  assert.notEqual(old, proxy);
  assert.equal(proxy, generate('/pmtiles/run-1/'));
  const theme = JSON.parse(fs.readFileSync(path.join(work, 'catalog/same-release/places/catalog.json')));
  assert.equal(theme.links.find((link) => link.rel === 'pmtiles').href, '/pmtiles/run-1/places.pmtiles');
  manifest.objects[0].uri = 's3://private-tiles/run-2/places.pmtiles';
  assert.notEqual(proxy, generate('/pmtiles/run-1/'));
});
