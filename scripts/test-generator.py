#!/usr/bin/env python3
"""Behavioural regressions for storage accounting, estimates and publication recovery."""
import importlib.util
import gzip
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'airgap/tile-generator'))
import capacity
import generator
import pmtiles_check


def inventory(theme='places', candidate=True, missing=False):
    return {'theme': theme, 'objects': [{'uri': f's3://source/{theme}.parquet', 'identity': 'etag:1000000', 'type': theme,
        'bytes': 1000000, 'row_groups': [{'index': 0, 'candidate': candidate, 'bbox_statistics_complete': not missing,
        'rows': 1000, 'compressed_bytes': 900000, 'uncompressed_bytes': 2000000, 'geometry_bytes': 500000, 'start': 4, 'end': 900004}]}]}


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()
    def config(self, **settings):
        return generator.Config({'PMTILES_SCRATCH_ROOT': str(self.root), 'OUTPUT': str(self.root / 'output'),
                                  'THEMES': 'places', **settings})
    def test_overlap_hardlinks_and_symlinks(self):
        sub = self.root / 'sub'; sub.mkdir()
        file = sub / 'payload'; file.write_bytes(b'x' * 8000)
        before = capacity.footprint([self.root])
        self.assertEqual(before, capacity.footprint([self.root, sub, self.root]))
        os.link(file, sub / 'hardlink')
        self.assertEqual(before, capacity.footprint([self.root]))
        external = Path(tempfile.gettempdir())
        (sub / 'external').symlink_to(external)
        self.assertLess(capacity.footprint([self.root]), before + 10000)
    def test_existing_occupancy_counts_toward_local_limit(self):
        (self.root / 'retained.pmtiles').write_bytes(b'x' * 20000)
        guard = capacity.Guard([self.root], 0, local_limit=10000)
        with self.assertRaisesRegex(RuntimeError, 'Combined local'):
            guard.check()
    def test_write_paths_cannot_escape_accounting_through_symlinks(self):
        external = self.root / 'existing-data'; external.mkdir()
        sentinel = external / 'keep.parquet'; sentinel.write_bytes(b'original')
        for index, (area, relative) in enumerate((('scratch', 'release'), ('output', 'publication'),
                                                ('output', 'data'), ('output', 'data/release/release/theme=places'))):
            with self.subTest(path=relative):
                case = self.root / str(index)
                link = case / area / relative
                link.parent.mkdir(parents=True)
                link.symlink_to(external, target_is_directory=True)
                with self.assertRaisesRegex(ValueError, 'contains a symlink'):
                    generator.Config({'PMTILES_SCRATCH_ROOT': str(case / 'scratch'), 'OUTPUT': str(case / 'output'),
                                      'RELEASE': 'release', 'THEMES': 'places', 'PRESERVE_PARQUET': 'true'})
                self.assertEqual(sentinel.read_bytes(), b'original')
    def test_sparse_budget_and_reported_allocation_are_distinct(self):
        file = self.root / 'sparse'
        with file.open('wb') as stream:
            stream.truncate(8 * 1024**2)
        guard = capacity.Guard([self.root], 0)
        guard.check()
        self.assertGreaterEqual(guard.measured()['peak_local_bytes'], file.stat().st_size)
        self.assertLess(guard.measured()['peak_reported_allocated_bytes'], guard.measured()['peak_local_bytes'])
    def test_capacity_floor(self):
        with self.assertRaisesRegex(RuntimeError, 'floor'):
            capacity.Guard([self.root], 10**30).check()
    def test_settings_validate_before_launch(self):
        for value in ('nan', 'inf', '-1', 'zero'):
            with self.assertRaises(ValueError): self.config(PMTILES_MAX_LOCAL_GB=value)
        for value in ('places,', 'places,places', ''):
            with self.assertRaises(ValueError): self.config(THEMES=value)
        with self.assertRaises(ValueError): self.config(THEME='places')
        with self.assertRaises(ValueError): self.config(PLANETILER_THREADS='1.5')
        with self.assertRaises(ValueError): self.config(PLANETILER_MMAP_TEMP='true')
    def test_bbox_validation(self):
        for value in ('1,2,3', 'nan,2,3,4', '1,2,1,3', '-181,2,3,4', '1,5,3,4'):
            with self.assertRaises(ValueError): capacity.bbox(value)
        self.assertEqual(capacity.bbox(''), [-180, -90, 180, 90])
    def test_estimate_local_max_and_s3_sum(self):
        config = self.config(); guard = config.guard()
        one = capacity.estimate([inventory()], config.settings(), guard)
        two = capacity.estimate([inventory(), inventory('buildings')], config.settings(), guard)
        self.assertEqual(one['local']['additional_peak_bytes_conservative'], two['local']['additional_peak_bytes_conservative'])
        self.assertEqual(one['s3']['additional_bytes_conservative'] * 2, two['s3']['additional_bytes_conservative'])
    def test_missing_stats_widen_range_and_not_zero(self):
        config = self.config(); guard = config.guard()
        a = capacity.estimate([inventory()], config.settings(), guard)
        b = capacity.estimate([inventory(missing=True)], config.settings(), guard)
        self.assertGreater(b['local']['additional_peak_bytes_conservative'], a['local']['additional_peak_bytes_conservative'])
    def test_empty_bbox_retains_archive_overhead(self):
        config = self.config()
        result = capacity.estimate([inventory(candidate=False)], config.settings(), config.guard())
        self.assertEqual(result['themes'][0]['candidate_rows'], 0)
        self.assertGreater(result['themes'][0]['pmtiles_bytes_expected'], 0)
    def test_stale_calibration_rejected(self):
        config = self.config(); data = [inventory()]
        calibration = {'source_fingerprint': 'stale', 'settings_fingerprint': capacity.fingerprint(config.settings()),
                       'coefficients': {'places': {'work_per_input_byte': 0, 'output_per_input_byte': 0}}}
        result = capacity.estimate(data, config.settings(), config.guard(), calibration)
        self.assertEqual(result['calibration_status'], 'rejected-stale')
        self.assertGreater(result['themes'][0]['feature_and_sort_bytes_expected'], 0)
    def test_prior_with_different_generation_settings_is_not_used(self):
        config = self.config()
        prior = {'profile_fingerprint': config.profile_hash, 'generation_settings': {'compress_temp': False},
                 'themes': {'places': {'work_per_input_byte': 0.001, 'output_per_input_byte': 0.001}}}
        result = capacity.estimate([inventory()], config.settings(), config.guard(), priors=prior)
        self.assertEqual(result['themes'][0]['confidence'], 'uncalibrated')
    def test_pilot_keeps_uncertainty_observed_in_compatible_regional_runs(self):
        config = self.config(); inputs = [inventory()]
        coefficients = {'places': {'work_per_input_byte': 1, 'output_per_input_byte': 1, 'uncertainty': 2.5}}
        calibration = {'source_fingerprint': capacity.source_fingerprint(inputs),
                       'settings_fingerprint': capacity.fingerprint(config.settings()), 'coefficients': coefficients}
        prior = {'profile_fingerprint': config.profile_hash, 'generation_settings': {'compress_temp': True},
                 'themes': {'places': {**coefficients['places'], 'uncertainty': 4}}}
        result = capacity.estimate(inputs, config.settings(), config.guard(), calibration, prior)
        self.assertEqual(result['themes'][0]['confidence'], 'source-calibrated')
        self.assertEqual(result['themes'][0]['planning_factor'], 4)
        self.assertEqual(result['themes'][0]['feature_and_sort_bytes_expected'], 900000)
    def test_invalid_calibration_cannot_imply_zero_capacity(self):
        config = self.config(); inputs = [inventory()]
        for value in (0, -1, float('nan'), float('inf'), '1', True):
            with self.subTest(value=value):
                calibration = {'source_fingerprint': capacity.source_fingerprint(inputs),
                               'settings_fingerprint': capacity.fingerprint(config.settings()),
                               'coefficients': {'places': {'work_per_input_byte': value, 'output_per_input_byte': 1}}}
                with self.assertRaisesRegex(ValueError, 'positive finite number'):
                    capacity.estimate(inputs, config.settings(), config.guard(), calibration)
    def test_capacity_cancellation_not_treated_as_unknown_s3(self):
        config = self.config(PMTILES_S3_PATH='s3://test/output')
        runner = generator.Runner(config, config.guard())
        with patch.object(runner, 'inventory', return_value=inventory()), patch.object(runner, 'java', side_effect=capacity.CapacityError('floor')):
            with self.assertRaises(capacity.CapacityError): generator.make_report(config, runner)
    def test_pilot_selection_includes_all_types(self):
        data = inventory(); other = inventory('address')['objects'][0]
        other['row_groups'][0]['rows'] = 0
        data['objects'].append(other)
        selection = capacity.pilot_selection(data)
        self.assertIn(data['objects'][0]['uri'], selection)
        self.assertIn(other['uri'], selection)
        self.assertEqual(selection[other['uri']][0]['limit'], 0)
    def test_dry_run_unchanged_state(self):
        config = self.config()
        publication = config.output / 'publication' / 'old.json'; publication.parent.mkdir(parents=True)
        publication.write_text('original')
        retained = self.root / 'failed.pmtiles'; retained.write_text('retained')
        before = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        report = capacity.estimate([inventory()], config.settings(), config.guard())
        with patch.dict(os.environ, config.env, clear=True), patch.object(generator, 'make_report', return_value=(report, [inventory()])):
            self.assertEqual(generator.main(['--dry-run']), 0)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})
    def test_pilot_cannot_inherit_export_publication_destination(self):
        with patch.dict(os.environ, {'EXPORT_S3_PREFIX': 's3://test/export'}):
            with self.assertRaisesRegex(ValueError, 'reserved'):
                generator.main(['--estimate-pilot'])
    def test_dry_run_refuses_overwriting_report(self):
        target = self.root / 'report.json'; target.write_text('keep')
        config = self.config()
        with patch.dict(os.environ, config.env, clear=True):
            with self.assertRaisesRegex(ValueError, 'new path'):
                generator.main(['--dry-run', '--report', str(target)])
        self.assertEqual(target.read_text(), 'keep')
    def test_explicit_report_is_capacity_monitored_and_partial_file_removed(self):
        guard = capacity.Guard([self.root], 0, local_limit=512 * 1024)
        with self.assertRaises(capacity.CapacityError):
            generator.atomic_json(self.root / 'report.json', {'metadata': ['x' * 1000] * 2000}, guard)
        self.assertFalse(list(self.root.iterdir()))
    def test_archive_validation_checks_tile_payload_crc(self):
        data = gzip.compress(b'')
        root = bytes([1, 0, 1, len(data), 1])
        metadata = b'{"vector_layers":[]}'
        tiles = 127 + len(root) + len(metadata)
        header = bytearray(127); header[:8] = b'PMTiles\x03'
        struct.pack_into('<11Q', header, 8, 127, len(root), 127 + len(root), len(metadata), tiles, 0, tiles, len(data), 1, 1, 1)
        header[97:102] = bytes([1, 2, 1, 0, 0])
        archive = self.root / 'test.pmtiles'
        archive.write_bytes(header + root + metadata + data)
        self.assertEqual(pmtiles_check.validate(archive)['addressed_tiles'], 1)
        corrupted = bytearray(archive.read_bytes()); corrupted[-1] ^= 1
        archive.write_bytes(corrupted)
        with self.assertRaises(gzip.BadGzipFile): pmtiles_check.validate(archive)
    def test_full_process_group_cancelled(self):
        config = self.config()
        class TripGuard:
            def __init__(self): self.calls = 0
            def check(self):
                self.calls += 1
                if self.calls > 4: raise RuntimeError('capacity exceeded')
        pidfile = self.root / 'child.pid'
        script = 'import subprocess,time,pathlib; p=subprocess.Popen(["sleep","60"]); pathlib.Path(' + repr(str(pidfile)) + ').write_text(str(p.pid)); time.sleep(60)'
        runner = generator.Runner(config, TripGuard())
        with self.assertRaisesRegex(RuntimeError, 'capacity exceeded'):
            runner.run([sys.executable, '-c', script], capture=True)
        pid = int(pidfile.read_text())
        status = Path(f'/proc/{pid}/stat')
        self.assertTrue(not status.exists() or status.read_text().split()[2] == 'Z')
    def test_archive_survives_failed_publication_and_next_run(self):
        config = self.config(PMTILES_S3_PATH='s3://test/new')
        report = capacity.estimate([inventory()], config.settings(), config.guard())
        def fake_planetiler(runner, conf, source, theme, part):
            output = part / 'places.pmtiles'; output.write_bytes(b'completed')
            return output, {}
        with patch.dict(os.environ, config.env, clear=True), patch.object(generator, 'make_report', return_value=(report, [inventory()])), patch.object(generator, 'planetiler', side_effect=fake_planetiler), patch.object(generator.Runner, 'ensure_destination'), patch.object(generator.Runner, 'publish', side_effect=RuntimeError('checksum mismatch')):
            for _ in range(2):
                with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
                    generator.main([])
        files = list(self.root.rglob('places.pmtiles'))
        self.assertEqual(len(files), 2)
        self.assertTrue(all(p.read_bytes() == b'completed' for p in files))
        self.assertEqual(len(list(config.output.rglob('latest-failure.json'))), 1)
    def test_success_removes_local_archive_and_writes_checksum(self):
        config = self.config(PMTILES_S3_PATH='s3://test/new')
        report = capacity.estimate([inventory()], config.settings(), config.guard())
        def fake_planetiler(runner, conf, source, theme, part):
            output = part / 'places.pmtiles'; output.write_bytes(b'completed')
            return output, {}
        def publish(runner, path, remote, temp):
            return {'uri': remote, 'size': path.stat().st_size, 'sha256': generator.sha256(path)}
        with patch.dict(os.environ, config.env, clear=True), patch.object(generator, 'make_report', return_value=(report, [inventory()])), patch.object(generator, 'planetiler', side_effect=fake_planetiler), patch.object(generator.Runner, 'ensure_destination'), patch.object(generator.Runner, 'publish', publish):
            generator.main([])
        self.assertFalse(list(self.root.rglob('*.pmtiles')))
        manifest = json.loads((config.output / 'publication' / f'{config.release}.json').read_text())
        self.assertEqual(len(manifest['objects'][0]['sha256']), 64)
        self.assertIn('diagnostic', manifest['objects'][0])
    def test_diagnostic_failure_retains_completed_archive(self):
        config = self.config(PMTILES_S3_PATH='s3://test/new')
        report = capacity.estimate([inventory()], config.settings(), config.guard())
        def fake_planetiler(runner, conf, source, theme, part):
            output = part / 'places.pmtiles'; output.write_bytes(b'completed')
            return output, {}
        with patch.dict(os.environ, config.env, clear=True), patch.object(generator, 'make_report', return_value=(report, [inventory()])), patch.object(generator, 'planetiler', side_effect=fake_planetiler), patch.object(generator.Runner, 'ensure_destination'), patch.object(generator.Runner, 'publish', side_effect=[{'size': 9, 'sha256': 'test'}, RuntimeError('diagnostic upload failed')]):
            with self.assertRaisesRegex(RuntimeError, 'diagnostic upload'):
                generator.main([])
        self.assertEqual(len(list(self.root.rglob('places.pmtiles'))), 1)


if __name__ == '__main__': unittest.main()
