#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const THEMES = ["base", "buildings", "places", "divisions", "transportation", "addresses"];

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

function parseBbox(value) {
  if (!value) return [-180, -90, 180, 90];
  const bbox = value.split(",").map(Number);
  if (bbox.length !== 4 || bbox.some((item) => !Number.isFinite(item))) {
    throw new Error("--bbox must be four comma-separated numbers");
  }
  return bbox;
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
  const tilesDir = path.resolve(required(args, "tiles-dir"));
  const dataDir = path.resolve(required(args, "data-dir"));
  const outDir = path.resolve(required(args, "out-dir"));
  const tileBase = normalizeUrlBase(args["tile-base"] || `/tiles/${release}/`);
  const bbox = parseBbox(args.bbox);

  const availableThemes = THEMES.filter((theme) => fs.existsSync(path.join(tilesDir, `${theme}.pmtiles`)));
  const now = new Date().toISOString();

  const rootCatalog = {
    stac_version: "1.0.0",
    type: "Catalog",
    id: "overture-airgap",
    title: "Overture Maps Airgap Catalog",
    description: "Local catalog generated for the airgapped Overture Explorer.",
    links: [
      { rel: "self", href: "./catalog.json", type: "application/json" },
      { rel: "child", href: `./${release}/catalog.json`, type: "application/json", title: release, latest: true },
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
