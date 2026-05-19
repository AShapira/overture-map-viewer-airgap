import { getStacData } from "@/lib/stacService";
import { getViewerConfig } from "@/lib/viewerConfig";

// Cache the manifest to avoid repeated fetches
let cachedManifest = null;
let manifestFetchPromise = null;

/**
 * Fetches the manifest from the STAC catalog
 * @returns {Promise<Object>} The manifest object
 */
async function fetchManifest() {
  if (cachedManifest) {
    return cachedManifest;
  }

  if (!manifestFetchPromise) {
    manifestFetchPromise = getStacData()
      .then(stacData => {
        // Construct manifest URL from the release URL
        const manifestUrl = new URL("manifest.geojson", stacData.releaseUrl).href;
        return fetch(manifestUrl);
      })
      .then(response => {
        if (!response.ok) {
          throw new Error(`Failed to fetch manifest: ${response.status} ${response.statusText}`);
        }
        return response.json();
      })
      .then(data => {
        cachedManifest = data.features.map((f)=>{
         return {
            'type': f.properties.ovt_type,
            'bbox': f.bbox,
            'path': f.properties.rel_path
         }
        });
        return cachedManifest;
      })
      .catch(error => {
        console.error('Error fetching manifest:', error);
        manifestFetchPromise = null; // Allow retry on next call
        throw error;
      });
  }

  return manifestFetchPromise;
}

/**
 * Gets the download catalog based on the current bbox and visible types
 * @param {Array} bbox The bounding box [minx, miny, maxx, maxy]
 * @param {Array} visibleTypes An array of type names that are currently visible on the map
 * @returns {Promise<Object>} A promise that resolves to an object with the 'basePath' and array of 'types'
 */
export async function getDownloadCatalog(bbox, visibleTypes) {
  try {
    const [manifest, config] = await Promise.all([fetchManifest(), getViewerConfig()]);

    let fileCatalog = {};
    let types = {};

   //  Create types mapping
    visibleTypes.forEach((type) => {
      types[type] = {
         'name' : type,
         'files': []
      }
    })

    fileCatalog.basePath = resolveDownloadBase(config.downloadBaseUrl);

    manifest.forEach(file => {
      // First, check if we want this type
      if (visibleTypes.includes(file.type)){
        //Now check if the file intersects the bbox
        if (intersects(bbox, file.bbox)) {
          types[file.type].files.push(file.path);
        }
      }
    });

    fileCatalog.types = Object.values(types).filter(
      (type) => type.files.length > 0
    );
    return fileCatalog;
  } catch (error) {
    console.error('Error getting download catalog:', error);
    throw error;
  }
}


// Calculate intersection given 4-item bbox list of [minx, miny, maxx, maxy]
function intersects(bb1, bb2) {
   return (
      bb1[0] < bb2[2] &&
      bb1[2] > bb2[0] &&
      bb1[1] < bb2[3] &&
      bb1[3] > bb2[1]
   );
}

function resolveDownloadBase(basePath) {
  const normalizedBasePath = basePath.endsWith("/") ? basePath : `${basePath}/`;

  if (/^https?:\/\//.test(normalizedBasePath)) return normalizedBasePath;
  if (typeof window !== "undefined" && window.location?.href) {
    return new URL(normalizedBasePath, window.location.href).href;
  }
  return normalizedBasePath;
}
