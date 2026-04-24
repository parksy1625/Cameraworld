export interface Reconstruction {
  id: string;
  capture_id: string;
  job_id: string;
  tileset_url: string | null;
  splat_url: string | null;
  pointcloud_url: string | null;
  center_lat: number | null;
  center_lon: number | null;
  center_alt: number | null;
  radius_m: number | null;
  created_at: string;
}

const API_BASE =
  (import.meta.env && (import.meta.env.VITE_API_BASE as string | undefined)) ??
  "http://localhost:8000";

export async function fetchReconstruction(captureId: string): Promise<Reconstruction> {
  const resp = await fetch(`${API_BASE}/captures/${captureId}/reconstruction`);
  if (!resp.ok) {
    throw new Error(`API ${resp.status}: ${await resp.text()}`);
  }
  return (await resp.json()) as Reconstruction;
}
