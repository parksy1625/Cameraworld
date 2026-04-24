import {
  Cartesian3,
  Ion,
  Math as CMath,
  Terrain,
  Viewer,
} from "cesium";

/** Initialise a Cesium viewer with default Earth terrain. */
export function createViewer(containerId: string): Viewer {
  // Ion token is optional for our use-case; set VITE_CESIUM_ION_TOKEN to upgrade
  // terrain / imagery quality. Without a token Cesium falls back to OSM imagery.
  const token = import.meta.env?.VITE_CESIUM_ION_TOKEN as string | undefined;
  if (token) Ion.defaultAccessToken = token;

  const viewer = new Viewer(containerId, {
    terrain: Terrain.fromWorldTerrain(),
    animation: false,
    timeline: false,
    baseLayerPicker: true,
    geocoder: false,
    homeButton: true,
    sceneModePicker: false,
    navigationHelpButton: false,
  });

  viewer.scene.globe.depthTestAgainstTerrain = true;
  return viewer;
}

export function flyToLla(viewer: Viewer, lat: number, lon: number, alt: number, radius: number) {
  const height = Math.max(radius * 3, 200);
  viewer.camera.flyTo({
    destination: Cartesian3.fromDegrees(lon, lat, alt + height),
    orientation: {
      heading: CMath.toRadians(0),
      pitch: CMath.toRadians(-45),
      roll: 0,
    },
    duration: 2.0,
  });
}
