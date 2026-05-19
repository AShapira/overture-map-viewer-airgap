import { getDownloadCatalog } from "@/lib/DownloadCatalog";
import { getStacData } from "@/lib/stacService";
import { getViewerConfig } from "@/lib/viewerConfig";

jest.mock("@/lib/stacService", () => ({
  getStacData: jest.fn(),
}));

jest.mock("@/lib/viewerConfig", () => ({
  getViewerConfig: jest.fn(),
}));

describe("getDownloadCatalog", () => {
  beforeEach(() => {
    jest.clearAllMocks();

    getStacData.mockResolvedValue({
      releaseUrl: "http://localhost:8088/catalog/2026-04-15.0/catalog.json",
    });
    getViewerConfig.mockResolvedValue({
      downloadBaseUrl: "/data/release/2026-04-15.0",
    });

    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: () =>
        Promise.resolve({
          features: [
            {
              bbox: [34, 32, 35, 33],
              properties: {
                ovt_type: "building",
                rel_path: "theme=buildings/type=building/filtered.parquet",
              },
            },
            {
              bbox: [30, 30, 31, 31],
              properties: {
                ovt_type: "land",
                rel_path: "theme=base/type=land/filtered.parquet",
              },
            },
          ],
        }),
    });
  });

  it("uses an absolute base URL, keeps parquet files relative, and omits empty visible types", async () => {
    const catalog = await getDownloadCatalog(
      [34.1, 32.1, 34.9, 32.9],
      ["building", "land", "place"]
    );

    expect(global.fetch).toHaveBeenCalledWith(
      "http://localhost:8088/catalog/2026-04-15.0/manifest.geojson"
    );
    expect(catalog).toEqual({
      basePath: "http://localhost/data/release/2026-04-15.0/",
      types: [
        {
          name: "building",
          files: ["theme=buildings/type=building/filtered.parquet"],
        },
      ],
    });
  });
});
