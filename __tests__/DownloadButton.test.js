import React from "react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import "@testing-library/jest-dom";
import DownloadButton from "@/components/nav/DownloadButton";
import { useMapInstance } from "@/lib/MapContext";
import { getViewerConfig } from "@/lib/viewerConfig";
import { getLatestReleaseVersion } from "@/lib/stacService";
import { getDownloadCatalog } from "@/lib/DownloadCatalog";
import { downloadAsZip } from "@/lib/zipDownload";
import { normalizeGeojson } from "@/lib/normalizeGeojson";
import {
  ParquetDataset,
  writeGeoJSON,
} from "@geoarrow/geoarrow-wasm/esm/index.js";

jest.mock("@/lib/MapContext", () => ({
  useMapInstance: jest.fn(),
}));

jest.mock("@/lib/viewerConfig", () => ({
  getViewerConfig: jest.fn(),
}));

jest.mock("@/lib/stacService", () => ({
  getLatestReleaseVersion: jest.fn(),
}));

jest.mock("@/lib/DownloadCatalog", () => ({
  getDownloadCatalog: jest.fn(),
}));

jest.mock("@/lib/LayerManager", () => ({
  getVisibleTypes: jest.fn(() => ["building"]),
}));

jest.mock("@/lib/zipDownload", () => ({
  downloadAsZip: jest.fn(),
}));

jest.mock("@/lib/downloadMetadata", () => ({
  buildDownloadMetadata: jest.fn(() => "metadata"),
}));

jest.mock("@/lib/normalizeGeojson", () => ({
  normalizeGeojson: jest.fn(() => "normalized-geojson"),
}));

jest.mock("@geoarrow/geoarrow-wasm/esm/index.js", () => ({
  __esModule: true,
  default: jest.fn(() => Promise.resolve()),
  ParquetDataset: jest.fn(),
  set_panic_hook: jest.fn(),
  writeGeoJSON: jest.fn(() => Uint8Array.from([1, 2, 3])),
}));

jest.mock("@/components/nav/DownloadDialog", () => {
  function MockDownloadDialog({ open, onConfirm, onCancel, bbox, zipName }) {
    if (!open) return null;
    return (
      <div role="dialog">
        <span data-testid="dialog-bbox">{bbox?.join(",")}</span>
        <span data-testid="dialog-zip-name">{zipName || "loading"}</span>
        <button type="button" onClick={onConfirm}>Confirm</button>
        <button type="button" onClick={onCancel}>Cancel</button>
      </div>
    );
  }

  return MockDownloadDialog;
});

const bounds = {
  getWest: () => 34.1,
  getSouth: () => 31.9,
  getEast: () => 34.2,
  getNorth: () => 32.0,
};

function renderButton({ zoom = 15 } = {}) {
  return render(
    <DownloadButton
      mode="theme-dark"
      zoom={zoom}
      setZoom={jest.fn()}
      visibleTypes={["building-footprint"]}
    />
  );
}

describe("DownloadButton", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    useMapInstance.mockReturnValue({
      getBounds: jest.fn(() => bounds),
      getZoom: jest.fn(() => 15),
    });
    getViewerConfig.mockResolvedValue({ download: { minZoom: 10 } });
    getLatestReleaseVersion.mockResolvedValue("2026-04-15.0");
    getDownloadCatalog.mockResolvedValue({
      basePath: "/data/release/2026-04-15.0/",
      types: [{ name: "building", files: ["building.parquet"] }],
    });
    ParquetDataset.mockImplementation(() =>
      Promise.resolve({
        read: jest.fn(() => Promise.resolve({ numBatches: 1 })),
      })
    );
    downloadAsZip.mockReturnValue({
      url: "blob:download",
      filename: "overture-2026-04-15.0-34.100,31.900,34.200,32.000.zip",
      revoke: jest.fn(),
    });
  });

  it("uses the runtime-configured minimum zoom", async () => {
    renderButton({ zoom: 12 });

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Download visible layers" })).toBeEnabled();
    });
  });

  it("opens the confirmation dialog with the captured bbox and archive name", async () => {
    renderButton();

    fireEvent.click(screen.getByRole("button", { name: "Download visible layers" }));

    expect(screen.getByRole("dialog")).toBeInTheDocument();
    expect(screen.getByTestId("dialog-bbox")).toHaveTextContent("34.1,31.9,34.2,32");
    await waitFor(() => {
      expect(screen.getByTestId("dialog-zip-name")).toHaveTextContent(
        "overture-2026-04-15.0-34.100,31.900,34.200,32.000.zip"
      );
    });
  });

  it("normalizes confirmed data and retains a visible fallback link", async () => {
    renderButton();

    fireEvent.click(screen.getByRole("button", { name: "Download visible layers" }));
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }));

    await waitFor(() => {
      expect(screen.getByRole("status")).toHaveTextContent("Download ready");
    });

    expect(writeGeoJSON).toHaveBeenCalled();
    expect(normalizeGeojson).toHaveBeenCalledWith(Uint8Array.from([1, 2, 3]));
    expect(downloadAsZip).toHaveBeenCalledWith(
      expect.arrayContaining([
        expect.objectContaining({
          name: expect.stringMatching(/building.*\.geojson$/),
          data: "normalized-geojson",
        }),
        expect.objectContaining({ name: "metadata.json" }),
      ]),
      "overture-2026-04-15.0-34.100,31.900,34.200,32.000.zip",
      { autoRevoke: false }
    );
  });
});
