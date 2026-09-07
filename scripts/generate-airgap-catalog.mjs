#!/usr/bin/env node

import fs from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import process from "node:process";

const SUPPORTED_THEMES = new Set(["base", "buildings", "places", "divisions", "transportation", "addresses"]);

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith("--")) continue;
    args[key.slice(2)] = argv[i + 1];
    i += 1;
  }
  return args;
}

function required(args, name) {
  if (!args[name]) {
    throw new Error(`Missing required --${name}`);
  }
  return args[name];
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function normalizeUrlBase(value) {
  return value.endsWith("/") ? value : `${value}/`;
}

function readPublicationManifest(file, release) {
  const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
  if (manifest.schema_version !== 1) throw new Error("Unsupported publication manifest schema_version");
  if (manifest.release !== release) throw new Error("Publication manifest release does not match --release");
  if (!Array.isArray(manifest.themes) || manifest.themes.length === 0) {
    throw new Error("Publication manifest must contain at least one theme");
  }
  if (!Array.isArray(manifest.bbox) || manifest.bbox.length !== 4 || manifest.bbox.some((value) => !Number.isFinite(value))) {
    throw new Error("Publication manifest bbox must contain four numbers");
  }

  const seen = new Set();
  for (const theme of manifest.themes) {
    if (!SUPPORTED_THEMES.has(theme)) throw new Error(`Unsupported published theme: ${theme}`);
    if (seen.has(theme)) throw new Error(`Duplicate published theme: ${theme}`);
    seen.add(theme);
  }

  if (!Array.isArray(manifest.objects) || manifest.objects.length !== manifest.themes.length) {
    throw new Error("Publication manifest objects do not match themes");
  }
  for (const [index, object] of manifest.objects.entries()) {
    const theme = manifest.themes[index];
    if (object?.theme !== theme || object?.filename !== `${theme}.pmtiles` ||
        typeof object?.uri !== "string" || !object.uri.endsWith(`/${theme}.pmtiles`) ||
        !Number.isSafeInteger(object?.size) || object.size <= 0) {
      throw new Error(`Invalid publication object for theme: ${theme}`);
    }
  }

  return manifest;
}

function parseBbox(value) {
  if (!value) return [-180, -90, 180, 90];
  const bbox = value.split(",").map(Number);
  if (bbox.length !== 4 || bbox.some((item) => !Number.isFinite(item))) {
    throw new Error("--bbox must be four comma-separated numbers");
  }
  return bbox;
}

function sameBbox(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function listParquetFiles(dataDir) {
  const files = [];
  if (!fs.existsSync(dataDir)) return files;

  for (const themeEntry of fs.readdirSync(dataDir, { withFileTypes: true })) {
    if (!themeEntry.isDirectory() || !themeEntry.name.startsWith("theme=")) continue;
    const theme = themeEntry.name.slice("theme=".length);
    const themeDir = path.join(dataDir, themeEntry.name);

    for (const typeEntry of fs.readdirSync(themeDir, { withFileTypes: true })) {
      if (!typeEntry.isDirectory() || !typeEntry.name.startsWith("type=")) continue;
      const type = typeEntry.name.slice("type=".length);
      const typeDir = path.join(themeDir, typeEntry.name);

      for (const fileEntry of fs.readdirSync(typeDir, { withFileTypes: true })) {
        if (!fileEntry.isFile() || !fileEntry.name.endsWith(".parquet")) continue;
        files.push({
          theme,
          type,
          relPath: `${themeEntry.name}/${typeEntry.name}/${fileEntry.name}`,
        });
      }
    }
  }

  return files.sort((a, b) => a.relPath.localeCompare(b.relPath));
}

function main() {
  const args = parseArgs(process.argv);
  const release = required(args, "release");
  const publicationManifest = path.resolve(required(args, "publication-manifest"));
  const dataDir = path.resolve(required(args, "data-dir"));
  const outDir = path.resolve(required(args, "out-dir"));
  const tileBase = normalizeUrlBase(required(args, "tile-base"));

  const publication = readPublicationManifest(publicationManifest, release);
  const bbox = parseBbox(publication.bbox?.join(","));
  if (args.bbox && !sameBbox(parseBbox(args.bbox), bbox)) {
    throw new Error("Publication manifest bbox does not match --bbox");
  }
  const availableThemes = publication.themes;
  const now = new Date().toISOString();
  // The browser caches theme URLs by the latest release URL. Include publication
  // identity and tile base so changing a gateway or region invalidates that cache.
  const revision = createHash("sha256").update(JSON.stringify({ publication, tileBase })).digest("hex").slice(0, 24);

  for (const theme of SUPPORTED_THEMES) {
    fs.rmSync(path.join(outDir, release, theme), { recursive: true, force: true });
  }

  const rootCatalog = {
    stac_version: "1.0.0",
    type: "Catalog",
    id: "overture-airgap",
    title: "Overture Maps Airgap Catalog",
    description: "Local catalog generated for the airgapped Overture Explorer.",
    links: [
      { rel: "self", href: "./catalog.json", type: "application/json" },
      { rel: "child", href: `./${release}/catalog.json?v=${revision}`, type: "application/json", title: release, latest: true },
    ],
  };

  const releaseCatalog = {
    stac_version: "1.0.0",
    type: "Catalog",
    id: release,
    title: `Overture ${release}`,
    description: "Airgapped Overture release catalog.",
    links: [
      { rel: "self", href: "./catalog.json", type: "application/json" },
      { rel: "root", href: "../catalog.json", type: "application/json" },
      { rel: "manifest", href: "./manifest.geojson", type: "application/geo+json" },
      ...availableThemes.map((theme) => ({
        rel: "child",
        href: `./${theme}/catalog.json`,
        type: "application/json",
        title: theme,
      })),
    ],
  };

  writeJson(path.join(outDir, "catalog.json"), rootCatalog);
  writeJson(path.join(outDir, release, "catalog.json"), releaseCatalog);

  for (const theme of availableThemes) {
    const themeCatalog = {
      stac_version: "1.0.0",
      type: "Catalog",
      id: theme,
      title: theme,
      description: `PMTiles for Overture ${theme}.`,
      links: [
        { rel: "self", href: "./catalog.json", type: "application/json" },
        { rel: "root", href: "../../catalog.json", type: "application/json" },
        { rel: "parent", href: "../catalog.json", type: "application/json" },
        { rel: "pmtiles", href: `${tileBase}${theme}.pmtiles`, type: "application/vnd.pmtiles" },
      ],
    };
    writeJson(path.join(outDir, release, theme, "catalog.json"), themeCatalog);
  }

  const manifest = {
    type: "FeatureCollection",
    name: `overture-${release}-manifest`,
    generated_at: now,
    bbox,
    features: listParquetFiles(dataDir).map((file, index) => ({
      type: "Feature",
      id: `${file.type}-${index}`,
      bbox,
      geometry: {
        type: "Polygon",
        coordinates: [[
          [bbox[0], bbox[1]],
          [bbox[2], bbox[1]],
          [bbox[2], bbox[3]],
          [bbox[0], bbox[3]],
          [bbox[0], bbox[1]],
        ]],
      },
      properties: {
        theme: file.theme,
        ovt_type: file.type,
        rel_path: file.relPath,
      },
    })),
  };

  writeJson(path.join(outDir, release, "manifest.geojson"), manifest);
  console.log(`Wrote airgap catalog for ${release}: ${availableThemes.length} theme(s), ${manifest.features.length} parquet file(s)`);
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
