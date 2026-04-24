import { Cesium3DTileset, Viewer } from "cesium";

/** Load a 3D Tiles tileset.json URL into a Cesium viewer. */
export async function loadTileset(
  viewer: Viewer,
  url: string,
): Promise<Cesium3DTileset> {
  const tileset = await Cesium3DTileset.fromUrl(url, {
    maximumScreenSpaceError: 8,
  });
  viewer.scene.primitives.add(tileset);
  return tileset;
}

export function removeTileset(viewer: Viewer, tileset: Cesium3DTileset): void {
  viewer.scene.primitives.remove(tileset);
}
