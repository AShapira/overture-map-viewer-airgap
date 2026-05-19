const DEFAULT_CONFIG = {
  stacCatalogUrl: "/catalog/catalog.json",
  downloadBaseUrl: "/data/",
  releaseId: "2026-04-15.0",
  geocoderBaseUrl: null,
  features: {
    search: false,
    download: true,
    externalDocs: false,
  },
};

let configPromise = null;

function normalizeBaseUrl(value, fallback) {
  const base = typeof value === "string" && value.length > 0 ? value : fallback;
  return base.endsWith("/") ? base : `${base}/`;
}

function mergeConfig(raw) {
  const cfg = raw && typeof raw === "object" ? raw : {};
  return {
    ...DEFAULT_CONFIG,
    ...cfg,
    downloadBaseUrl: normalizeBaseUrl(cfg.downloadBaseUrl, DEFAULT_CONFIG.downloadBaseUrl),
    features: {
      ...DEFAULT_CONFIG.features,
      ...(cfg.features || {}),
    },
  };
}

export async function getViewerConfig() {
  if (!configPromise) {
    const basePath = process.env.NEXT_PUBLIC_BASE_PATH || "";
    configPromise = fetch(`${basePath}/config/viewer-config.json`, { cache: "no-store" })
      .then((response) => {
        if (!response.ok) return DEFAULT_CONFIG;
        return response.json();
      })
      .then(mergeConfig)
      .catch(() => DEFAULT_CONFIG);
  }
  return configPromise;
}

export function resetViewerConfigForTests() {
  configPromise = null;
}
