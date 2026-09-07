"""Storage accounting and explicitly approximate GeoParquet capacity estimates."""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import shutil

GIB = 1024**3
THEMES = ("base", "buildings", "places", "divisions", "transportation", "addresses")


class CapacityError(RuntimeError):
    """Capacity cancellation must never be downgraded to missing metadata."""


def positive(value, name, default=None):
    if value in (None, ""):
        return default
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise ValueError(f"{name} must be a positive finite number")
    return number


def bbox(value):
    if not value:
        return [-180., -90., 180., 90.]
    v = [float(x) for x in value.split(",")]
    if len(v) != 4 or not all(math.isfinite(x) for x in v) or not (-180 <= v[0] < v[2] <= 180 and -90 <= v[1] < v[3] <= 90):
        raise ValueError("BBOX must be west,south,east,north within longitude/latitude limits")
    return v


def themes(value):
    items = [x.strip() for x in value.split(",")]
    if not items or any(x not in THEMES for x in items) or len(items) != len(set(items)):
        raise ValueError("THEMES must be a nonempty ordered subset without duplicates: " + ",".join(THEMES))
    return items


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def existing_parent(path):
    path = Path(path).absolute()
    while not path.exists():
        parent = path.parent
        if parent == path:
            raise ValueError(f"No existing parent for {path}")
        path = parent
    return path


def measured_footprint(roots):
    """Count allocated bytes once, including hardlinks and overlapping bind mounts.

    Never follow symlinks out of the managed directory. Walking errors fail closed.
    Windows mounts occasionally report zero allocation for a nonempty file: use
    its logical size there instead of claiming the disk usage is zero.
    """
    seen = set()
    total = 0
    allocated = 0
    stack = [Path(p) for p in roots if Path(p).exists()]
    while stack:
        path = stack.pop()
        try:
            stat = path.lstat()
        except FileNotFoundError:  # Planetiler can delete a chunk during sampling.
            continue
        key = (stat.st_dev, stat.st_ino)
        if key in seen:
            continue
        seen.add(key)
        total += max(getattr(stat, "st_blocks", 0) * 512, stat.st_size if not path.is_dir() else 0)
        allocated += stat.st_blocks * 512 if hasattr(stat, 'st_blocks') else stat.st_size
        if path.is_dir() and not path.is_symlink():
            with os.scandir(path) as entries:
                stack.extend(Path(e.path) for e in entries)
    return total, allocated


def footprint(roots):
    return measured_footprint(roots)[0]


class Guard:
    def __init__(self, roots, reserve, local_limit=None, theme_limit=None):
        self.roots = [Path(p) for p in roots]
        self.reserve = reserve
        self.local_limit = local_limit
        self.theme_limit = theme_limit
        self.theme = None
        self.initial, self.initial_allocated = measured_footprint(self.roots)
        self.peak = self.initial
        self.peak_allocated = self.initial_allocated
        self.theme_peak = 0
        self.work_peak = 0
        self.minimum_free = {}

    def filesystems(self):
        result = {}
        for root in self.roots:
            parent = existing_parent(root)
            key = str(parent.stat().st_dev)
            free = shutil.disk_usage(parent).free
            if key not in result or free < result[key]["free_bytes"]:
                result[key] = {"path": str(parent), "free_bytes": free}
        return list(result.values())

    def check(self):
        for fs in self.filesystems():
            key = fs["path"]
            self.minimum_free[key] = min(self.minimum_free.get(key, fs["free_bytes"]), fs["free_bytes"])
            if fs["free_bytes"] < self.reserve:
                raise CapacityError(f"Free space crossed the configured {self.reserve / GIB:g} GiB floor: {key}")
        used, allocated = measured_footprint(self.roots)
        self.peak = max(self.peak, used)
        self.peak_allocated = max(self.peak_allocated, allocated)
        if self.local_limit and used >= self.local_limit:
            raise CapacityError(f"Combined local footprint reached the configured {self.local_limit / GIB:g} GiB ceiling")
        if self.theme:
            self.theme_peak = max(self.theme_peak, footprint([self.theme]))
            self.work_peak = max(self.work_peak, footprint([self.theme / "work"]))
            if self.theme_limit and self.theme_peak >= self.theme_limit:
                raise CapacityError(f"theme scratch reached the configured {self.theme_limit / GIB:g} GiB ceiling")

    def measured(self):
        return {"initial_local_bytes": self.initial, "peak_local_bytes": self.peak,
                "peak_additional_local_bytes": max(0, self.peak - self.initial),
                "initial_reported_allocated_bytes": self.initial_allocated,
                "peak_reported_allocated_bytes": self.peak_allocated,
                "peak_newly_allocated_bytes": max(0, self.peak_allocated - self.initial_allocated),
                "peak_theme_scratch_bytes": self.theme_peak, "peak_work_bytes": self.work_peak,
                "minimum_free_bytes": self.minimum_free, "sampling_interval_seconds": 0.5}


def source_fingerprint(inventories):
    return fingerprint([{ "theme": i["theme"], "objects": [(o["uri"], o["identity"], o["bytes"]) for o in i["objects"]]} for i in inventories])


def estimate(inventories, settings, guard, calibration=None, priors=None, remote_existing=None, source_existing=None):
    identity = {"source_fingerprint": source_fingerprint(inventories), "settings_fingerprint": fingerprint(settings)}
    valid = bool(calibration and all(calibration.get(k) == v for k, v in identity.items()))
    records = []
    cumulative_preserved = 0
    expected_peak = conservative_peak = 0
    for inventory in inventories:
        theme = inventory["theme"]
        all_groups = [g for o in inventory["objects"] for g in o["row_groups"]]
        groups = [g for g in all_groups if g["candidate"]]
        compressed = sum(g["compressed_bytes"] for g in groups)
        raw = sum(g["uncompressed_bytes"] for g in groups)
        rows = sum(g["rows"] for g in groups)
        missing = sum(not g["bbox_statistics_complete"] for g in groups)
        coefficients = calibration.get("coefficients", {}).get(theme) if valid else None
        source_calibrated = coefficients is not None
        prior = (priors or {}).get("themes", {}).get(theme)
        compatible_prior = prior and (priors or {}).get("profile_fingerprint") == settings["profile_fingerprint"] and all(
            settings.get(k) == v for k, v in (priors or {}).get("generation_settings", {}).items())
        if coefficients is None and compatible_prior:
            coefficients = prior
        calibrated = bool(coefficients)
        # An uncalibrated source-byte heuristic is reported honestly; it is never
        # interpreted as a measured safety bound. Measurements replace these priors.
        coefficients = coefficients or {"work_per_input_byte": 3.0, "output_per_input_byte": 1.5, "uncertainty": 4.0}
        for key in ("work_per_input_byte", "output_per_input_byte", "uncertainty"):
            value = coefficients.get(key, 2.5 if key == "uncertainty" else None)
            if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
                raise ValueError(f"Invalid {theme} calibration coefficient: {key} must be a positive finite number")
        # A small pilot must not narrow away variation already observed in
        # compatible complete regional runs.
        uncertainty = max(1.5, coefficients.get("uncertainty", 2.5),
                          prior.get("uncertainty", 1.5) if compatible_prior else 1.5) * (2 if missing else 1)
        # Candidate bytes include complete intersecting row groups: no area-ratio extrapolation.
        work = int(compressed * coefficients["work_per_input_byte"])
        archive = max(32 * 1024, int(compressed * coefficients["output_per_input_byte"]))
        preservation = max(compressed, raw) if settings["preserve_parquet"] else 0
        overhead = 32 * 1024**2
        expected = work + archive + overhead
        conservative = math.ceil(expected * uncertainty)
        expected_peak = max(expected_peak, cumulative_preserved + expected + preservation)
        conservative_peak = max(conservative_peak, cumulative_preserved + conservative + preservation)
        cumulative_preserved += preservation
        records.append({"theme": theme, "source_bytes": sum(o["bytes"] for o in inventory["objects"]),
                        "candidate_rows": rows, "exact_selected_rows": None, "candidate_compressed_bytes": compressed,
                        "candidate_uncompressed_bytes": raw, "row_groups_without_bbox_statistics": missing,
                        "feature_and_sort_bytes_expected": work, "pmtiles_bytes_expected": archive,
                        "feature_storage_bytes_expected": work, "sorting_additional_copy_bytes_expected": 0,
                        "sorting_model": "Planetiler 0.10.2 rewrites the same chunk paths after reading each group into memory; no second complete on-disk sort copy. Work coefficient includes observed feature-store peak.",
                        "pmtiles_bytes_conservative": math.ceil(archive * uncertainty),
                        "preserved_parquet_bytes_conservative": preservation,
                        "scratch_bytes_expected": expected, "scratch_bytes_conservative": conservative,
                        "confidence": "source-calibrated" if source_calibrated else "measured-prior" if calibrated else "uncalibrated",
                        "planning_factor": uncertainty,
                        "coefficients": coefficients})
    new_s3 = sum(r["pmtiles_bytes_expected"] for r in records) + len(records) * 8 * 1024**2
    new_s3_high = sum(r["pmtiles_bytes_conservative"] for r in records) + len(records) * 8 * 1024**2
    filesystems = guard.filesystems()
    available = min(fs["free_bytes"] for fs in filesystems) - guard.reserve
    if guard.local_limit:
        available = min(available, guard.local_limit - guard.initial)
    fits = conservative_peak <= available and all(not guard.theme_limit or r["scratch_bytes_conservative"] <= guard.theme_limit for r in records)
    source_s3 = sum(o["bytes"] for i in inventories for o in i["objects"] if o["uri"].startswith("s3://"))
    return {"schema_version": 1, "mode": "estimate", **identity, "settings": settings,
            "calibration_status": "matched" if valid else "rejected-stale" if calibration else "not-supplied",
            "measured_prior_provenance": (priors or {}).get("provenance"),
            "inputs": inventories,
            "themes": records, "local": {"existing_bytes": guard.initial, "additional_peak_bytes_expected": expected_peak,
            "additional_peak_bytes_conservative": conservative_peak, "total_peak_bytes_conservative": guard.initial + conservative_peak,
            "final_additional_bytes_conservative": cumulative_preserved + 32 * 1024**2,
            "reserve_bytes": guard.reserve, "local_limit_bytes": guard.local_limit, "theme_limit_bytes": guard.theme_limit,
            "available_for_new_bytes": max(0, available), "headroom_bytes": available - conservative_peak,
            "fits_estimated_capacity": fits, "filesystems": filesystems},
            "s3": {"existing_selected_source_bytes": source_s3, "existing_destination_bytes": remote_existing,
            "existing_source_release_bytes": source_existing,
            "other_retained_outputs_bytes": None, "diagnostics_bytes_conservative": len(records) * 8 * 1024**2,
            "additional_bytes_expected": new_s3, "additional_bytes_conservative": new_s3_high,
            "quota_bytes": None, "free_bytes": None},
            "warnings": ["Planning ranges are extrapolations, not guaranteed bounds or statistical confidence intervals.",
                         "Candidate rows include complete intersecting row groups; exact BBOX row counts require reading data.",
                         "Local S3, container images, VHDX allocation and other host workloads require separate host accounting."]}


def pilot_selection(inventory, rows_per_group=3000):
    """Deterministically cover every type and low/median/high byte and geometry groups."""
    candidates = {}
    for obj in inventory["objects"]:
        for group in obj["row_groups"]:
            if group["candidate"] and group["rows"]:
                candidates.setdefault(obj["type"], []).append((obj, group))
    selected = {}
    for values in candidates.values():
        choices = {}
        for field in ("rows", "rows_per_square_degree", "geometry_bytes", "compressed_bytes"):
            ordered = sorted(values, key=lambda v: (v[1].get(field) or 0, v[0]["uri"], v[1]["index"]))
            for index in (0, len(ordered) // 2, len(ordered) - 1):
                obj, group = ordered[index]
                choices[(obj["uri"], group["index"])] = (obj, group)
        for obj, group in choices.values():
            selected.setdefault(obj["uri"], []).append({"start": group["start"], "end": group["end"], "limit": rows_per_group})
    # Valid empty themes must still provide a schema for Planetiler.
    for obj in inventory["objects"]:
        if not any(x["type"] == obj["type"] and x["uri"] in selected for x in inventory["objects"]):
            selected[obj["uri"]] = [{"start": 0, "end": 2**63 - 1, "limit": 0}]
    return selected
