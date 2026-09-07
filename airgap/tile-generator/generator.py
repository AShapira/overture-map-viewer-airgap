#!/usr/bin/env python3
"""Shared Windows/RHEL container lifecycle; no runtime package downloads."""
from __future__ import annotations
import argparse
from collections import deque
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
from capacity import GIB, Guard, CapacityError, bbox, estimate, fingerprint, pilot_selection, positive, themes
from pmtiles_check import validate

APP = Path(__file__).resolve().parent
JAVA_TOOL = 'com.onthegomap.planetiler.reader.parquet.AirgapTools'


def boolean(env, key, default):
    value = env.get(key, default)
    if value not in ('true', 'false'):
        raise ValueError(f'{key} must be true or false')
    return value == 'true'


class Config:
    def __init__(self, env):
        self.env = dict(env)
        if 'THEME' in env:
            raise ValueError('THEME is no longer supported; set the comma-separated THEMES value instead')
        self.release = env.get('RELEASE', '2026-04-15.0')
        if not re.fullmatch(r'[A-Za-z0-9._-]+', self.release) or self.release in ('.', '..'):
            raise ValueError('RELEASE contains unsupported characters')
        self.themes = themes(env.get('THEMES', 'base,buildings,places,divisions,transportation,addresses'))
        self.box = bbox(env.get('BBOX', ''))
        self.bbox_arg = env.get('BBOX', '')
        self.source = env.get('SOURCE_PATH', '/input/release')
        self.remote = env.get('PMTILES_S3_PATH', '').rstrip('/')
        self.scratch = Path(env.get('PMTILES_SCRATCH_ROOT', '/scratch')).resolve()
        self.output = Path(env.get('OUTPUT', '/output')).resolve()
        self.reserve = positive(env.get('PMTILES_MIN_FREE_GB'), 'PMTILES_MIN_FREE_GB', 1) * GIB
        self.theme_limit = positive(env.get('PMTILES_MAX_SCRATCH_GB'), 'PMTILES_MAX_SCRATCH_GB')
        self.local_limit = positive(env.get('PMTILES_MAX_LOCAL_GB'), 'PMTILES_MAX_LOCAL_GB')
        self.preserve = boolean(env, 'PRESERVE_PARQUET', 'false')
        self.check_write_path(self.scratch, Path(self.release))
        self.check_write_path(self.output, Path('publication') / f'{self.release}.json')
        if self.preserve:
            for theme in self.themes:
                self.check_write_path(self.output, Path('data/release') / self.release / f'theme={theme}')
        if self.preserve and not self.source.startswith('s3://'):
            source_dir = Path(self.source).resolve()
            preserved_dir = (self.output / 'data' / 'release' / self.release).resolve()
            if source_dir == preserved_dir or source_dir in preserved_dir.parents or preserved_dir in source_dir.parents:
                raise ValueError('Preserved output must be separate from the read-only source dataset')
        self.compress = boolean(env, 'PLANETILER_COMPRESS_TEMP', 'true')
        self.mmap = boolean(env, 'PLANETILER_MMAP_TEMP', 'false')
        if self.compress and self.mmap:
            raise ValueError('PLANETILER_MMAP_TEMP must be false when PLANETILER_COMPRESS_TEMP=true')
        self.threads = self.integer(env, 'PLANETILER_THREADS', 12)
        self.readers = self.integer(env, 'PLANETILER_SORT_MAX_READERS', 1)
        self.writers = self.integer(env, 'PLANETILER_SORT_MAX_WRITERS', 1)
        self.env['AWS_REGION'] = env.get('S3_REGION', env.get('AWS_REGION', 'us-west-2'))
        self.env['AWS_EC2_METADATA_DISABLED'] = 'true'
        self.profile_hash = fingerprint({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((APP / 'profiles').glob('*.java'))})

    @staticmethod
    def check_write_path(root, relative):
        # Footprint accounting does not traverse symlinks. Never redirect owned
        # writes or preserved-dataset replacement through an existing link.
        target = root
        for part in relative.parts:
            target = target / part
            if target.is_symlink():
                raise ValueError(f'Writable processing/output path contains a symlink: {target}')

    @staticmethod
    def integer(env, name, default):
        value = positive(env.get(name), name, default)
        if int(value) != value:
            raise ValueError(f'{name} must be a positive integer')
        return int(value)

    def settings(self):
        return {'release': self.release, 'bbox': self.box, 'themes': self.themes,
                'scope': 'bbox' if self.bbox_arg else 'world',
                'theme_maxzoom': {t: {'base': 13, 'divisions': 12}.get(t, 14) for t in self.themes},
                'profile_fingerprint': self.profile_hash, 'planetiler_version': '0.10.2',
                'image_identity': self.env.get('GENERATOR_IMAGE_ID', 'not-provided'),
                'compress_temp': self.compress, 'mmap_temp': self.mmap, 'sort_readers': self.readers,
                'sort_writers': self.writers, 'threads': self.threads, 'preserve_parquet': self.preserve}

    def guard(self):
        # Windows exports overlapping binds as different virtual devices. The
        # native wrapper identifies their common enclosing host directory.
        enclosing = self.env.get('PMTILES_ACCOUNTING_ROOT', '')
        roots = [self.scratch, self.output]
        if enclosing:
            parent = Path(enclosing).resolve()
            if parent not in roots:
                raise ValueError('PMTILES_ACCOUNTING_ROOT must be a configured scratch/output root')
            roots = [parent]
        return Guard(roots, self.reserve,
                     self.local_limit * GIB if self.local_limit else None,
                     self.theme_limit * GIB if self.theme_limit else None)


def sha256(path):
    with Path(path).open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def atomic_json(path, data, guard=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        if guard:
            guard.check()
        with temporary.open('x') as file:
            since_check = 0
            for chunk in json.JSONEncoder(indent=2, allow_nan=False).iterencode(data):
                file.write(chunk)
                since_check += len(chunk)
                if guard and since_check >= 1024**2:
                    file.flush(); guard.check(); since_check = 0
            file.write('\n')
        if guard:
            guard.check()
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


class Runner:
    def __init__(self, config, guard):
        self.config, self.guard = config, guard
        self.process = None
        self.tail = deque()
        self.tail_bytes = 0

    def stop(self):
        process = self.process
        if process is None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def run(self, command, *, capture=False, cwd=None, env=None):
        self.guard.check()
        output, read_error = [], []
        self.process = subprocess.Popen(command, cwd=cwd, env=env or self.config.env,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        process = self.process

        def consume():
            try:
                for data in iter(lambda: process.stdout.read1(65536), b''):
                    if capture:
                        output.append(data)
                    else:
                        sys.stdout.buffer.write(data); sys.stdout.buffer.flush()
                    self.tail.append(data); self.tail_bytes += len(data)
                    while self.tail_bytes > 8 * 1024**2:
                        self.tail_bytes -= len(self.tail.popleft())
            except Exception as error:
                read_error.append(error)

        reader = threading.Thread(target=consume, daemon=True)
        reader.start()
        try:
            while process.poll() is None:
                self.guard.check()
                time.sleep(0.5)
            reader.join(timeout=10)
            if reader.is_alive():
                raise RuntimeError('Child process left its output stream open')
            if read_error:
                raise read_error[0]
            if process.returncode:
                details = b''.join(output).decode(errors='replace')[-4000:] if capture else ''
                raise RuntimeError(f'{Path(command[0]).name} failed with status {process.returncode}. {details}')
            self.guard.check()
            return b''.join(output).decode(errors='replace')
        except BaseException:
            self.stop()
            reader.join(timeout=10)
            raise
        finally:
            process.stdout.close()
            self.process = None

    def java(self, *args, temp=None, capture=False):
        command = ['java', '-XX:-UsePerfData', '-XX:MaxRAMPercentage=65']
        if temp:
            command.append(f'-Djava.io.tmpdir={temp}')
        command += ['-cp', f'{APP}/s3-parquet-adapter.jar:{APP}/planetiler.jar', JAVA_TOOL, *map(str, args)]
        return self.run(command, capture=capture)

    def inventory(self, source, theme):
        output = self.java('inventory', source, theme, self.config.bbox_arg, capture=True)
        return json.loads(next(line for line in reversed(output.splitlines()) if line.startswith('{')))

    def publish(self, path, remote, temp):
        size, digest = path.stat().st_size, sha256(path)
        self.run(['s5cmd', 'cp', str(path), remote])
        self.java('verify-remote', remote, size, digest, temp=temp)
        return {'uri': remote, 'size': size, 'sha256': digest}

    def ensure_destination(self):
        output = self.java('destination', self.config.remote, capture=True)
        state = json.loads(next(line for line in reversed(output.splitlines()) if line.startswith('{')))
        if state['archives']:
            raise ValueError('Destination contains published PMTiles. Choose a new PMTILES_S3_PATH prefix; existing maps are never overwritten.')


def planetiler(runner, config, source, theme, root):
    work = root / 'work'
    work.mkdir(parents=True)
    temp = work / 'java-tmp'; temp.mkdir()
    output = root / f'{theme}.pmtiles'
    args = ['java', '-XX:-UsePerfData', '-XX:MaxRAMPercentage=65', f'-Djava.io.tmpdir={temp}',
            '-cp', f'{APP}/s3-parquet-adapter.jar:{APP}/planetiler.jar', str(APP / 'profiles' / f'{theme.capitalize()}.java'),
            f'--data={source}', f'--output={output}', f'--tmpdir={work / "tmp"}',
            f'--compress-temp={str(config.compress).lower()}', f'--mmap-temp={str(config.mmap).lower()}',
            f'--sort-max-readers={config.readers}', f'--sort-max-writers={config.writers}', f'--threads={config.threads}']
    if config.bbox_arg:
        args.append(f'--bounds={config.bbox_arg}')
    started = time.monotonic()
    runner.run(args, cwd=work)
    validation = validate(output, config.box if config.bbox_arg else None)
    metrics = {**runner.guard.measured(), 'elapsed_seconds': round(time.monotonic() - started, 3), 'validation': validation}
    shutil.rmtree(work)
    return output, metrics


def make_report(config, runner, calibration_path=None):
    inventories = [runner.inventory(config.source, theme) for theme in config.themes]
    calibration = json.loads(Path(calibration_path).read_text()) if calibration_path else None
    priors_file = APP / 'capacity-priors.json'
    priors = json.loads(priors_file.read_text()) if priors_file.exists() else None
    def occupancy(uri):
        if not uri.startswith('s3://'):
            return None
        try:
            result = runner.java('destination', uri, capture=True)
            return json.loads(next(line for line in reversed(result.splitlines()) if line.startswith('{')))['bytes']
        except CapacityError:
            raise
        except RuntimeError:
            return None
    return estimate(inventories, config.settings(), runner.guard, calibration, priors,
                    occupancy(config.remote), occupancy(config.source)), inventories


def show_report(report):
    settings, local, remote = report['settings'], report['local'], report['s3']
    def size(value):
        return 'unknown' if value is None else f'{value/GIB:.2f} GiB'
    print(f"Release: {settings['release']}; scope: {settings['scope']}; BBOX: {settings['bbox']}", flush=True)
    print(f"Ordered themes: {', '.join(settings['themes'])}; source fingerprint: {report['source_fingerprint']}", flush=True)
    print(f"Profile: {settings['profile_fingerprint']}; image: {settings['image_identity']}", flush=True)
    print(f"Planetiler {settings['planetiler_version']}; threads={settings['threads']}; compressed temp={settings['compress_temp']}; "
          f"mmap={settings['mmap_temp']}; sorting readers/writers={settings['sort_readers']}/{settings['sort_writers']}; "
          f"preserve Parquet={settings['preserve_parquet']}; maximum zooms={settings['theme_maxzoom']}", flush=True)
    provenance = report.get('measured_prior_provenance') or {}
    print(f"Calibration: {report['calibration_status']}; measured prior: {provenance.get('date', 'none')} "
          f"({provenance.get('release', 'unknown release')}); see per-theme confidence below.", flush=True)
    print('Theme             candidate rows   work GiB   PMTiles GiB   scratch high GiB  confidence', flush=True)
    for theme in report['themes']:
        print(f"{theme['theme']:17} {theme['candidate_rows']:14,d} {theme['feature_and_sort_bytes_expected']/GIB:10.2f} "
              f"{theme['pmtiles_bytes_expected']/GIB:13.2f} {theme['scratch_bytes_conservative']/GIB:18.2f}  {theme['confidence']}", flush=True)
        print(f"  Source {size(theme['source_bytes'])}; candidate compressed/raw {size(theme['candidate_compressed_bytes'])}/"
              f"{size(theme['candidate_uncompressed_bytes'])}; missing BBOX statistics in {theme['row_groups_without_bbox_statistics']} groups; "
              'exact selected rows unknown.', flush=True)
        print(f"  Scratch expected {size(theme['scratch_bytes_expected'])}; PMTiles conservative {size(theme['pmtiles_bytes_conservative'])}; "
              f"preserved Parquet allowance {size(theme['preserved_parquet_bytes_conservative'])}; "
              f"planning factor {theme['planning_factor']:g}; sorting additional complete copy 0 GiB.", flush=True)
    print(f"Existing local occupancy: {size(local['existing_bytes'])}; combined/theme limits: "
          f"{size(local['local_limit_bytes'])}/{size(local['theme_limit_bytes'])}; free-space reserve: {size(local['reserve_bytes'])}.", flush=True)
    print(f"Additional local peak: {local['additional_peak_bytes_expected']/GIB:.2f}–{local['additional_peak_bytes_conservative']/GIB:.2f} GiB; "
          f"available after reserve/limit: {local['available_for_new_bytes']/GIB:.2f} GiB; fits estimate: {local['fits_estimated_capacity']}", flush=True)
    print(f"Conservative total local peak: {size(local['total_peak_bytes_conservative'])}; remaining headroom: {size(local['headroom_bytes'])}; "
          f"final additional local allowance: {size(local['final_additional_bytes_conservative'])}.", flush=True)
    print(f"Existing S3 selected source/release: {size(remote['existing_selected_source_bytes'])}/{size(remote['existing_source_release_bytes'])}; "
          f"destination: {size(remote['existing_destination_bytes'])}; other retained outputs: {size(remote['other_retained_outputs_bytes'])}.", flush=True)
    print(f"Additional S3: {report['s3']['additional_bytes_expected']/GIB:.2f}–{report['s3']['additional_bytes_conservative']/GIB:.2f} GiB. "
          'S3 free capacity/quota: unknown. These are planning ranges, not guaranteed bounds.', flush=True)
    print(f"S3 diagnostics allowance: {size(remote['diagnostics_bytes_conservative'])}.", flush=True)
    for warning in report['warnings']:
        print('Note: ' + warning, flush=True)


def pilot(config, runner, report, inventories, root):
    coefficients, samples = {}, []
    original_limit = runner.guard.theme_limit
    runner.guard.theme_limit = min(original_limit or float('inf'), positive(config.env.get('PMTILES_PILOT_MAX_GB'), 'PMTILES_PILOT_MAX_GB', 5) * GIB)
    try:
        for inventory in inventories:
            theme = inventory['theme']
            part = root / theme; part.mkdir()
            runner.guard.theme = part; runner.guard.theme_peak = runner.guard.work_peak = 0
            selection = part / 'selection.json'
            atomic_json(selection, pilot_selection(inventory), runner.guard)
            sample = part / 'sample'
            runner.java('export', config.source, theme, config.bbox_arg, sample, selection, temp=root)
            sampled = runner.inventory(str(sample), theme)
            selected_bytes = sum(g['compressed_bytes'] for o in sampled['objects'] for g in o['row_groups'])
            archive, metrics = planetiler(runner, config, str(sample), theme, part)
            if selected_bytes:
                coefficients[theme] = {'work_per_input_byte': max(0.1, metrics['peak_work_bytes'] / selected_bytes),
                                       'output_per_input_byte': archive.stat().st_size / selected_bytes, 'uncertainty': 2.5}
            samples.append({'theme': theme, 'sample_input_bytes': selected_bytes, **metrics})
            shutil.rmtree(part)
    finally:
        runner.guard.theme_limit = original_limit; runner.guard.theme = None
    return {'schema_version': 1, 'source_fingerprint': report['source_fingerprint'],
            'settings_fingerprint': report['settings_fingerprint'], 'coefficients': coefficients, 'samples': samples,
            'method': 'Deterministic first records from low/median/high row count, spatial density, geometry bytes and compressed bytes per type; bounded pilot, not a random statistical sample.'}


def generate(config, runner, report, root):
    objects = []
    started = time.monotonic()
    for theme in config.themes:
        theme_started = time.monotonic()
        runner.guard.check()
        part = root / theme; part.mkdir()
        runner.guard.theme = part; runner.guard.theme_peak = runner.guard.work_peak = 0
        runner.tail.clear(); runner.tail_bytes = 0
        print(f'Generating {theme} directly from {config.source}; run directory {part}', flush=True)
        archive, metrics = planetiler(runner, config, config.source, theme, part)
        atomic_json(part / 'completed.json', {'archive': str(archive), 'sha256': sha256(archive), **metrics})
        if config.preserve:
            # Export on the destination filesystem, avoiding a cross-filesystem promotion copy.
            parent = config.output / 'data' / 'release' / config.release
            parent.mkdir(parents=True, exist_ok=True)
            stage = parent / ('.staging-' + root.name + '-' + theme)
            stage.mkdir(exist_ok=False)
            try:
                runner.java('export', config.source, theme, config.bbox_arg, stage, temp=part)
                destination = parent / f'theme={theme}'
                backup = destination.with_name(destination.name + '.backup-' + root.name) if destination.exists() else None
                if backup:
                    destination.rename(backup)
                try:
                    (stage / f'theme={theme}').rename(destination)
                except BaseException:
                    if backup and not destination.exists():
                        backup.rename(destination)
                    raise
                if backup:
                    shutil.rmtree(backup)
            finally:
                shutil.rmtree(stage)
        remote = f'{config.remote}/{theme}.pmtiles'
        uploaded = runner.publish(archive, remote, part)
        metrics['capacity'] = runner.guard.measured()
        log = part / 'generator.log.gz'
        with gzip.open(log, 'wb') as file:
            for data in runner.tail:
                file.write(data)
        diagnostic = runner.publish(log, f'{config.remote}/diagnostics/{root.name}/{theme}.log.gz', part)
        archive.unlink()
        metrics['total_elapsed_seconds'] = round(time.monotonic() - theme_started, 3)
        objects.append({'theme': theme, 'filename': f'{theme}.pmtiles', **uploaded, 'metrics': metrics, 'diagnostic': diagnostic})
        shutil.rmtree(part)
        runner.guard.theme = None
        print(f"Published and removed local archive for {theme} ({uploaded['size']} bytes)", flush=True)
    manifest = {'schema_version': 1, 'release': config.release, 'run_id': root.name,
                'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'bbox': config.box,
                'themes': config.themes, 'objects': objects, 'settings': config.settings(),
                'elapsed_seconds': round(time.monotonic() - started, 3),
                'capacity': runner.guard.measured(), 'estimate': {k: v for k, v in report.items() if k != 'inputs'}}
    atomic_json(config.output / 'publication' / f'{config.release}.json', manifest, runner.guard)
    (config.output / 'publication' / 'latest-failure.json').unlink(missing_ok=True)
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--dry-run', action='store_true')
    modes.add_argument('--estimate-pilot', action='store_true')
    parser.add_argument('--report', help='Explicit output JSON report path')
    parser.add_argument('--calibration', help='Previously generated pilot calibration JSON')
    args = parser.parse_args(argv)
    if os.environ.get('EXPORT_S3_PREFIX'):
        raise ValueError('EXPORT_S3_PREFIX is reserved for the regional-source helper, not generator modes')
    config = Config(os.environ)
    guard = config.guard(); runner = Runner(config, guard)
    if not config.scratch.is_dir():
        raise ValueError('PMTILES_SCRATCH_ROOT must be an existing mounted directory')
    if not args.dry_run and not args.estimate_pilot and not re.match(r'^s3://[^/]+/.+', config.remote):
        raise ValueError('PMTILES_S3_PATH must be an s3://bucket/prefix URI')
    if args.report:
        target = Path(args.report).resolve()
        if target.exists() or config.output / 'publication' in target.parents:
            raise ValueError('Estimate report must be a new path outside publication state')
        if not any(p in target.parents for p in (config.output, config.scratch)):
            raise ValueError('Report must be inside monitored OUTPUT or PMTILES_SCRATCH_ROOT')
    report, inventories = make_report(config, runner, args.calibration)
    show_report(report)
    if args.dry_run:
        if args.report:
            atomic_json(args.report, report, guard)
        return 0
    if not args.estimate_pilot:
        runner.ensure_destination()
    run_id = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + uuid.uuid4().hex[:12]
    root = config.scratch / config.release / run_id
    root.mkdir(parents=True, exist_ok=False)
    config.env.update({'TMPDIR': str(root), 'TMP': str(root), 'TEMP': str(root)})

    def interrupted(signum, frame):
        runner.stop()
        raise InterruptedError(f'Received signal {signum}')

    signal.signal(signal.SIGTERM, interrupted); signal.signal(signal.SIGINT, interrupted)
    try:
        result = pilot(config, runner, report, inventories, root) if args.estimate_pilot else generate(config, runner, report, root)
        if args.report:
            atomic_json(args.report, result, guard)
        elif args.estimate_pilot:
            print(json.dumps(result, indent=2))
        return 0
    except BaseException as error:
        runner.stop()
        completed = list(root.glob('*/completed.json'))
        retained = [str(p.parent) for p in completed if list(p.parent.glob('*.pmtiles'))]
        for child in root.iterdir():
            if child.is_dir() and str(child) not in retained:
                shutil.rmtree(child)
        failure = {'run_id': run_id, 'error': str(error)[-4000:], 'retained_completed_archives': retained,
                   'capacity': guard.measured(), 'log_tail': b''.join(runner.tail)[-64 * 1024:].decode(errors='replace')}
        atomic_json(config.output / 'publication' / 'latest-failure.json', failure)
        if retained:
            print('Retained completed archive(s): ' + ', '.join(retained), file=sys.stderr)
        raise
    finally:
        if root.exists() and not list(root.iterdir()):
            root.rmdir()


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
