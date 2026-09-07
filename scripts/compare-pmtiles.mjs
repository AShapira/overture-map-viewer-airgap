// Compare every occupied coordinate and decoded MVT feature at every configured zoom.
import assert from 'node:assert/strict';
import { open, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { PMTiles, tileIdToZxy } from 'pmtiles';
import { VectorTile } from '@mapbox/vector-tile';
import Pbf from 'pbf';

const root = process.argv[2];
if (!root) throw new Error('Usage: node scripts/compare-pmtiles.mjs TEST_OUTPUT');
const inputs = JSON.parse(await readFile(join(root, 'comparison-input.json')));
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])]));
  return value;
}
function decode(data) {
  const tile = new VectorTile(new Pbf(new Uint8Array(data)));
  return Object.fromEntries(Object.entries(tile.layers).sort(([a], [b]) => a.localeCompare(b)).map(([name, layer]) => {
    const features = Array.from({length: layer.length}, (_, i) => {
      const feature = layer.feature(i);
      return JSON.stringify(canonical({id: feature.id, type: feature.type, properties: feature.properties,
        geometry: feature.loadGeometry().map(ring => ring.map(p => [p.x, p.y]))}));
    }).sort();
    return [name, {version: layer.version, extent: layer.extent, features}];
  }));
}
const summary = {};
for (const theme of Object.keys(inputs.baseline)) {
  const left = inputs.baseline[theme], right = inputs.optimized[theme];
  const ids = left.tile_content_hashes.map(([id]) => id);
  assert.deepEqual(ids, right.tile_content_hashes.map(([id]) => id), `${theme} coordinates`);
  for (const key of ['bbox', 'minzoom', 'maxzoom', 'layers']) assert.deepEqual(left[key], right[key], `${theme} ${key}`);
  const files = await Promise.all(['baseline', 'optimized'].map(mode => open(join(root, mode, `${theme}.pmtiles`))));
  const readers = files.map((file, i) => new PMTiles({getKey: () => `${theme}-${i}`,
    getBytes: async (offset, length) => { const bytes = Buffer.alloc(length); const {bytesRead} = await file.read(bytes, 0, length, offset); return {data: bytes.buffer.slice(0, bytesRead)}; }}));
  const zooms = Object.fromEntries(Array.from({length: left.maxzoom - left.minzoom + 1}, (_, i) => [left.minzoom + i, 0]));
  try {
    for (const id of ids) {
      const xyz = tileIdToZxy(id);
      const tiles = await Promise.all(readers.map(reader => reader.getZxy(...xyz)));
      assert.ok(tiles.every(Boolean), `${theme} missing tile ${xyz}`);
      assert.deepEqual(decode(tiles[0].data), decode(tiles[1].data), `${theme} decoded tile ${xyz}`);
      zooms[xyz[0]]++;
    }
  } finally { await Promise.all(files.map(file => file.close())); }
  summary[theme] = {decoded_tiles_compared: ids.length, zooms, layers: left.layers,
    baseline_peak: left.metrics.peak_theme_scratch_bytes, optimized_peak: right.metrics.peak_theme_scratch_bytes};
}
await writeFile(join(root, 'decoded-comparison.json'), JSON.stringify(summary, null, 2) + '\n', {flag: 'wx'});
console.log(JSON.stringify(summary, null, 2));
