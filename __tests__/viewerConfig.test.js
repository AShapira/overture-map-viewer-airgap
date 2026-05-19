import { getViewerConfig, resetViewerConfigForTests } from "@/lib/viewerConfig";

const CONFIG_URL = "/config/viewer-config.json";

function mockConfigResponse(config) {
  global.fetch = jest.fn((url) => {
    if (url !== CONFIG_URL) {
      return Promise.reject(new Error(`unexpected URL: ${url}`));
    }

    return Promise.resolve({
      ok: true,
      json: () => Promise.resolve(config),
    });
  });
}

describe("viewerConfig", () => {
  afterEach(() => {
    resetViewerConfigForTests();
    jest.restoreAllMocks();
  });

  it("defaults download.minZoom to 15 when it is missing", async () => {
    mockConfigResponse({});

    await expect(getViewerConfig()).resolves.toMatchObject({
      download: { minZoom: 15 },
    });
  });

  it("uses a valid numeric download.minZoom value", async () => {
    mockConfigResponse({ download: { minZoom: 13 } });

    await expect(getViewerConfig()).resolves.toMatchObject({
      download: { minZoom: 13 },
    });
  });

  it.each([
    ["string", "13"],
    ["negative", -1],
    ["NaN", NaN],
    ["Infinity", Infinity],
    ["null", null],
  ])("falls back to 15 when download.minZoom is %s", async (_label, minZoom) => {
    mockConfigResponse({ download: { minZoom } });

    await expect(getViewerConfig()).resolves.toMatchObject({
      download: { minZoom: 15 },
    });
  });
});
