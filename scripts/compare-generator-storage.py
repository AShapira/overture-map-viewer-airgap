#!/usr/bin/env python3
"""Run inside the generator image against explicitly supplied bounded read-only input.

Produces both archives for semantic comparison. These are test artifacts, never
published or deleted automatically. OUTPUT must be a new empty test directory.
"""
import json
import os
from pathlib import Path
import sys
sys.path.insert(0, '/app')
from generator import Config, Runner, planetiler, atomic_json
from pmtiles_check import validate

config = Config(os.environ)
if any(config.output.iterdir()):
    raise ValueError('Baseline comparison requires a new empty OUTPUT directory')
results = {}
for mode, compress, mmap in [('baseline', 'false', 'true'), ('optimized', 'true', 'false')]:
    current = Config({**os.environ, 'PLANETILER_COMPRESS_TEMP': compress, 'PLANETILER_MMAP_TEMP': mmap})
    guard = current.guard()
    runner = Runner(current, guard)
    results[mode] = {}
    for theme in current.themes:
        root = current.output / mode / theme
        root.mkdir(parents=True, exist_ok=False)
        guard.theme = root
        guard.theme_peak = guard.work_peak = 0
        source = current.source
        if mode == 'baseline':
            source = str(root / 'filtered-source')
            runner.java('export', current.source, theme, current.bbox_arg, source, temp=root)
        archive, metrics = planetiler(runner, current, source, theme, root)
        result = validate(archive, current.box, content_hashes=True)
        target = current.output / mode
        target.mkdir(exist_ok=True)
        archive.rename(target / archive.name)
        results[mode][theme] = {'metrics': metrics, **result}
atomic_json(config.output / 'comparison-input.json', results)
print(json.dumps({m: {t: {k: v for k, v in r.items() if k != 'tile_content_hashes'} for t, r in themes.items()} for m, themes in results.items()}, indent=2))
