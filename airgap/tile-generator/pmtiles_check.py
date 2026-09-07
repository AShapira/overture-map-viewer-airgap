"""Streaming PMTiles v3 directory validation without downloading a second archive."""
import gzip
import hashlib
import json
from pathlib import Path
import struct


def varint(data, pos):
    value = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            raise ValueError("Truncated PMTiles directory")
        byte = data[pos]; pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, pos
    raise ValueError("Invalid PMTiles varint")


def directory(data):
    count, pos = varint(data, 0)
    if count > len(data):
        raise ValueError("Invalid PMTiles directory count")
    ids, runs, sizes, offsets = [], [], [], []
    previous = 0
    for _ in range(count):
        delta, pos = varint(data, pos); previous += delta; ids.append(previous)
    for array in (runs, sizes):
        for _ in range(count):
            value, pos = varint(data, pos); array.append(value)
    for i in range(count):
        value, pos = varint(data, pos)
        if value == 0 and i == 0:
            raise ValueError("Invalid first directory offset")
        offsets.append(offsets[i - 1] + sizes[i - 1] if value == 0 else value - 1)
    if pos != len(data):
        raise ValueError("Trailing PMTiles directory bytes")
    return zip(ids, runs, sizes, offsets)


def validate(path, expected_bbox=None, content_hashes=False):
    path = Path(path)
    size = path.stat().st_size
    with path.open("rb") as file:
        header = file.read(127)
        if len(header) != 127 or header[:8] != b"PMTiles\x03":
            raise ValueError("Invalid PMTiles v3 header")
        root, root_size, meta, meta_size, leaves, leaves_size, tiles, tiles_size, addressed, entries, contents = struct.unpack_from("<11Q", header, 8)
        compression, tile_compression = header[97], header[98]
        if header[99] != 1 or header[100] > header[101] or header[101] > 26:
            raise ValueError("Invalid vector tile type/zoom range")
        bounds = [v / 1e7 for v in struct.unpack_from("<4i", header, 102)]
        if expected_bbox is not None and any(abs(a - b) > 1e-6 for a, b in zip(bounds, expected_bbox)):
            raise ValueError(f"PMTiles bounds {bounds} differ from expected {expected_bbox}")
        for offset, length in ((root, root_size), (meta, meta_size), (leaves, leaves_size), (tiles, tiles_size)):
            if offset < 127 or length < 0 or offset + length > size:
                raise ValueError("PMTiles section outside archive")

        def read(offset, length, codec):
            file.seek(offset); data = file.read(length)
            if len(data) != length:
                raise ValueError("Truncated PMTiles section")
            if codec == 2:
                return gzip.decompress(data)
            if codec != 1:
                raise ValueError(f"Unsupported PMTiles compression {codec}")
            return data

        metadata = json.loads(read(meta, meta_size, compression))
        seen_dirs = set()
        found_entries = found_addressed = 0
        unique_contents = set()
        hashes = []
        previous_end = -1

        def walk(offset, length, depth=0):
            nonlocal found_entries, found_addressed, previous_end
            if depth > 3 or (offset, length) in seen_dirs or length > 64 * 1024**2:
                raise ValueError("Invalid/cyclic PMTiles directory")
            seen_dirs.add((offset, length))
            for tile_id, run, length, offset in directory(read(offset, length, compression)):
                if run == 0:
                    if offset + length > leaves_size:
                        raise ValueError("Leaf outside PMTiles section")
                    walk(leaves + offset, length, depth + 1)
                else:
                    if length == 0 or offset + length > tiles_size or tile_id <= previous_end:
                        raise ValueError("Invalid PMTiles tile offset/order")
                    previous_end = tile_id + run - 1
                    if tile_id < (4 ** header[100] - 1) // 3 or previous_end >= (4 ** (header[101] + 1) - 1) // 3:
                        raise ValueError("Tile ID outside declared zoom range")
                    found_entries += 1; found_addressed += run
                    payload = None
                    if (offset, length) not in unique_contents or content_hashes:
                        # Verify every unique gzip payload/CRC, not just the index.
                        payload = read(tiles + offset, length, tile_compression)
                    unique_contents.add((offset, length))
                    if content_hashes:
                        digest = hashlib.sha256(payload).hexdigest()
                        hashes.extend((i, digest) for i in range(tile_id, tile_id + run))
        walk(root, root_size)
        if (found_entries, found_addressed, len(unique_contents)) != (entries, addressed, contents):
            raise ValueError("PMTiles directory counts do not match header")
        result = {"bytes": size, "bbox": bounds, "minzoom": header[100], "maxzoom": header[101],
                  "addressed_tiles": addressed, "tile_entries": entries, "tile_contents": contents,
                  "layers": [x["id"] for x in metadata.get("vector_layers", [])]}
        if content_hashes:
            result["tile_content_hashes"] = hashes
        return result
