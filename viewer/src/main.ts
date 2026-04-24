import "cesium/Build/Cesium/Widgets/widgets.css";
import { Cesium3DTileset } from "cesium";

import { fetchReconstruction } from "./api";
import { createViewer, flyToLla } from "./scene";
import { attachSplatOverlay, type SplatOverlay } from "./splat-overlay";
import { loadTileset, removeTileset } from "./tileset-loader";

const viewer = createViewer("app");
let currentTileset: Cesium3DTileset | null = null;
let currentSplat: SplatOverlay | null = null;

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

    if (rec.tileset_url) {
      currentTileset = await loadTileset(viewer, rec.tileset_url);
    }

    if (rec.center_lat != null && rec.center_lon != null) {
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
