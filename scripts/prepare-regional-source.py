#!/usr/bin/env python3
"""Validation helper, run inside the generator image with a fresh scratch bind.

SOURCE_PATH is the read-only complete release; BBOX/THEMES choose genuine
regional records. EXPORT_S3_PREFIX must be a fresh destination. Each bounded
partition is uploaded and fully SHA-256 verified before its staging file is
removed. No unrelated data or empty-type stand-ins are introduced.
"""
import json
import os
from pathlib import Path
import signal
import sys
import time
sys.path.insert(0, '/app')
from generator import Config, Runner

config = Config(os.environ)
if not config.env.get('EXPORT_S3_PREFIX', '').startswith('s3://'):
    raise ValueError('EXPORT_S3_PREFIX must identify a fresh S3 destination')
if not config.bbox_arg:
    raise ValueError('Regional validation requires an explicit BBOX')
if any(config.scratch.iterdir()):
    raise ValueError('Regional validation requires a new empty scratch directory')
config.env.update(TMPDIR=str(config.scratch), TMP=str(config.scratch), TEMP=str(config.scratch))
guard = config.guard()
guard.theme = config.scratch
runner = Runner(config, guard)
state = runner.java('destination', config.env['EXPORT_S3_PREFIX'], capture=True)
if json.loads(next(line for line in reversed(state.splitlines()) if line.startswith('{')))['bytes']:
    raise ValueError('Regional source destination already contains objects')

def stop(signum, frame):
    runner.stop()
    raise InterruptedError(f'Received signal {signum}')

signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)
started = time.monotonic()
try:
    for theme in config.themes:
        runner.java('export', config.source, theme, config.bbox_arg, config.scratch, temp=config.scratch)
        guard.check()
finally:
    runner.stop()
    print(json.dumps({'source_preparation_seconds': time.monotonic() - started, 'capacity': guard.measured()}))
