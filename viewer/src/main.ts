import "cesium/Build/Cesium/Widgets/widgets.css";
import { Cartesian3, Cesium3DTileset, Color, Entity } from "cesium";

import { fetchReconstruction } from "./api";
import { createViewer, flyToLla } from "./scene";
import { attachSplatOverlay, type SplatOverlay } from "./splat-overlay";
import { loadTileset, removeTileset } from "./tileset-loader";

const viewer = createViewer("app");
let currentTileset: Cesium3DTileset | null = null;
let currentSplat: SplatOverlay | null = null;
let currentPin: Entity | null = null;

const captureIdInput = document.getElementById("capture-id") as HTMLInputElement;
const loadBtn = document.getElementById("load") as HTMLButtonElement;
const toggleBtn = document.getElementById("toggle-splat") as HTMLButtonElement;
const statusEl = document.getElementById("status")!;

function setStatus(msg: string): void {
  statusEl.textContent = msg;
}

loadBtn.addEventListener("click", async () => {
  const id = captureIdInput.value.trim();
  if (!id) return;
  try {
    setStatus("loading reconstruction…");
    const rec = await fetchReconstruction(id);

    if (currentTileset) {
      removeTileset(viewer, currentTileset);
      currentTileset = null;
    }
    if (currentSplat) {
      currentSplat.dispose();
      currentSplat = null;
    }
    if (currentPin) {
      viewer.entities.remove(currentPin);
      currentPin = null;
    }

    if (rec.tileset_url) {
      currentTileset = await loadTileset(viewer, rec.tileset_url);
    }

    if (rec.center_lat != null && rec.center_lon != null) {
      // Drop a pin at the reconstruction centroid so it's discoverable
      // when zoomed out, and stays visible even if the tileset is hidden.
      currentPin = viewer.entities.add({
        name: `capture ${id.slice(0, 8)}`,
        position: Cartesian3.fromDegrees(
          rec.center_lon,
          rec.center_lat,
          rec.center_alt ?? 0,
        ),
        point: {
          pixelSize: 12,
          color: Color.CYAN,
          outlineColor: Color.WHITE,
          outlineWidth: 2,
        },
        label: {
          text: `${rec.radius_m ? rec.radius_m.toFixed(0) : "?"} m`,
          font: "12px system-ui",
          pixelOffset: new Cartesian3(0, -18, 0),
          fillColor: Color.WHITE,
          outlineColor: Color.BLACK,
          outlineWidth: 2,
          style: 2 /* FILL_AND_OUTLINE */,
          showBackground: true,
          backgroundColor: Color.BLACK.withAlpha(0.5),
        },
      });

      flyToLla(
        viewer,
        rec.center_lat,
        rec.center_lon,
        rec.center_alt ?? 0,
        rec.radius_m ?? 50,
      );
    }

    if (rec.splat_url && rec.center_lat != null && rec.center_lon != null) {
      currentSplat = await attachSplatOverlay(viewer, rec.splat_url, {
        lat: rec.center_lat,
        lon: rec.center_lon,
        alt: rec.center_alt ?? 0,
      });
      currentSplat.setVisible(false); // off by default
    }

    setStatus("loaded");
  } catch (e) {
    console.error(e);
    setStatus(`error: ${(e as Error).message}`);
  }
});

let splatVisible = false;
toggleBtn.addEventListener("click", () => {
  if (!currentSplat) {
    setStatus("no splat available");
    return;
  }
  splatVisible = !splatVisible;
  currentSplat.setVisible(splatVisible);
  setStatus(splatVisible ? "splat: on" : "splat: off");
});

// Auto-load when ?capture=<uuid> is present — lets the camo Flutter app
// open the viewer in a WebView already pointed at a specific capture.
const params = new URLSearchParams(window.location.search);
const auto = params.get("capture");
if (auto) {
  captureIdInput.value = auto;
  loadBtn.click();
}
