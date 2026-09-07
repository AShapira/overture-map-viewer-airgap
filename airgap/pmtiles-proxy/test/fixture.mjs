// A valid, deliberately tiny PMTiles v3 archive containing one MVT point at 0,0.
// Generated in tests, so CI does not need external geospatial data.
export function tinyArchive() {
  const varint = (value) => { const bytes = []; do { const b = value % 128; value = Math.floor(value / 128); bytes.push(b | (value ? 128 : 0)); } while (value); return Buffer.from(bytes); };
  const field = (id, bytes) => Buffer.concat([varint((id << 3) | 2), varint(bytes.length), bytes]);
  const feature = Buffer.concat([Buffer.from([8, 1, 24, 1]), field(4, Buffer.concat([varint(9), varint(4096), varint(4096)]))]);
  const layer = Buffer.concat([field(1, Buffer.from('place')), field(2, feature), Buffer.from([40, 128, 32, 120, 2])]);
  const tile = field(3, layer);
  const directory = Buffer.concat([Buffer.from([1, 0, 1]), varint(tile.length), Buffer.from([1])]);
  const metadata = Buffer.from(JSON.stringify({ vector_layers: [{ id: 'place', fields: {} }] }));
  const header = Buffer.alloc(127);
  Buffer.from('504d54696c657303', 'hex').copy(header);
  for (const [offset, value] of [[8, 127], [16, directory.length], [24, 127 + directory.length], [32, metadata.length],
    [40, 127 + directory.length + metadata.length], [48, 0], [56, 127 + directory.length + metadata.length],
    [64, tile.length], [72, 1], [80, 1], [88, 1]]) header.writeBigUInt64LE(BigInt(value), offset);
  header.set([1, 1, 1, 1, 0, 0], 96); // clustered, no compression, MVT, z0
  for (const [offset, value] of [[102, -180], [106, -85], [110, 180], [114, 85]]) header.writeInt32LE(value * 1e7, offset);
  return Buffer.concat([header, directory, metadata, tile]);
}
