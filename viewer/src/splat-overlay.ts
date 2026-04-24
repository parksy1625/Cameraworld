/**
 * Lightweight Gaussian Splat overlay.
 *
 * Cesium has no native support for splatting yet, so the overlay renders a
 * separate three.js canvas on top of the Cesium canvas and fakes depth by
 * listening to Cesium camera events. For MVP we load the splat as a point
 * cloud (one vertex per Gaussian centroid) — it's not photoreal, but it
 * proves the wire-up end-to-end. Replace with a proper splat renderer
 * (e.g. @mkkellogg/gaussian-splats-3d) for production.
 */

import * as THREE from "three";
import { Viewer, Cartesian3, Math as CMath } from "cesium";

export interface SplatOverlay {
  setVisible(v: boolean): void;
  dispose(): void;
}

export async function attachSplatOverlay(
  viewer: Viewer,
  splatPlyUrl: string,
  anchor: { lat: number; lon: number; alt: number },
): Promise<SplatOverlay> {
  const container = viewer.container as HTMLElement;
  const canvas = document.createElement("canvas");
  canvas.style.position = "absolute";
  canvas.style.top = "0";
  canvas.style.left = "0";
  canvas.style.pointerEvents = "none";
  canvas.style.width = "100%";
  canvas.style.height = "100%";
  container.appendChild(canvas);

  const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });
  renderer.setPixelRatio(window.devicePixelRatio);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(60, 1, 0.1, 10000);

  // Anchor splats at the reconstruction centroid (local ENU frame).
  const anchorEcef = Cartesian3.fromDegrees(anchor.lon, anchor.lat, anchor.alt);

  const geometry = await loadPlyAsPoints(splatPlyUrl);
  const material = new THREE.PointsMaterial({
    size: 0.05,
    vertexColors: true,
    sizeAttenuation: true,
  });
  const points = new THREE.Points(geometry, material);
  scene.add(points);

  function resize() {
    const w = container.clientWidth;
    const h = container.clientHeight;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  }
  resize();
  window.addEventListener("resize", resize);

  let visible = true;

  const unlisten = viewer.scene.postRender.addEventListener(() => {
    if (!visible) return;
    syncCameraFromCesium(viewer, camera, anchorEcef);
    renderer.render(scene, camera);
  });

  return {
    setVisible(v: boolean) {
      visible = v;
      canvas.style.display = v ? "block" : "none";
    },
    dispose() {
      unlisten();
      window.removeEventListener("resize", resize);
      renderer.dispose();
      geometry.dispose();
      material.dispose();
      canvas.remove();
    },
  };
}

function syncCameraFromCesium(
  viewer: Viewer,
  threeCam: THREE.PerspectiveCamera,
  anchorEcef: Cartesian3,
): void {
  const cesiumCam = viewer.camera;
  const posEcef = cesiumCam.positionWC;
  const relX = posEcef.x - anchorEcef.x;
  const relY = posEcef.y - anchorEcef.y;
  const relZ = posEcef.z - anchorEcef.z;

  threeCam.position.set(relX, relZ, -relY); // simple ECEF -> three y-up swap
  threeCam.lookAt(0, 0, 0);
  threeCam.fov = CMath.toDegrees(cesiumCam.frustum.fovy ?? Math.PI / 3);
  threeCam.updateProjectionMatrix();
}

async function loadPlyAsPoints(url: string): Promise<THREE.BufferGeometry> {
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`splat fetch ${resp.status}`);
  const buf = await resp.arrayBuffer();

  const { vertices, colors } = parsePlyXyzRgb(buf);
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(vertices, 3));
  if (colors.length === vertices.length) {
    geometry.setAttribute("color", new THREE.Float32BufferAttribute(colors, 3));
  }
  return geometry;
}

/** Minimal PLY parser: reads only x,y,z + (optional) red,green,blue. */
function parsePlyXyzRgb(buf: ArrayBuffer): {
  vertices: Float32Array;
  colors: Float32Array;
} {
  const text = new TextDecoder().decode(buf.slice(0, 8192));
  const headerEnd = text.indexOf("end_header");
  if (headerEnd < 0) throw new Error("ply: no end_header");
  const headerText = text.slice(0, headerEnd);
  const headerBytes = new TextEncoder().encode(text.slice(0, headerEnd + "end_header\n".length))
    .length;

  let count = 0;
  const props: { name: string; type: string }[] = [];
  let inVertex = false;
  for (const line of headerText.split(/\r?\n/)) {
    if (line.startsWith("element vertex")) {
      count = Number(line.split(/\s+/)[2]);
      inVertex = true;
    } else if (line.startsWith("element ") && !line.startsWith("element vertex")) {
      inVertex = false;
    } else if (inVertex && line.startsWith("property ")) {
      const [, type, name] = line.split(/\s+/);
      props.push({ type, name });
    }
  }

  // Compute byte offsets for each property.
  const sizeOf: Record<string, number> = {
    float: 4,
    float32: 4,
    double: 8,
    uchar: 1,
    uint8: 1,
    int: 4,
    uint: 4,
  };
  let stride = 0;
  const offsets: Record<string, number> = {};
  for (const p of props) {
    offsets[p.name] = stride;
    stride += sizeOf[p.type] ?? 4;
  }

  const vertices = new Float32Array(count * 3);
  const colors = new Float32Array(count * 3);
  const dv = new DataView(buf, headerBytes);

  for (let i = 0; i < count; i++) {
    const base = i * stride;
    vertices[i * 3 + 0] = dv.getFloat32(base + offsets.x, true);
    vertices[i * 3 + 1] = dv.getFloat32(base + offsets.y, true);
    vertices[i * 3 + 2] = dv.getFloat32(base + offsets.z, true);
    if ("red" in offsets) {
      colors[i * 3 + 0] = dv.getUint8(base + offsets.red) / 255;
      colors[i * 3 + 1] = dv.getUint8(base + offsets.green) / 255;
      colors[i * 3 + 2] = dv.getUint8(base + offsets.blue) / 255;
    }
  }
  return { vertices, colors };
}
