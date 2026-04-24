# 파이프라인 상세

`pipeline/cameraworld_pipeline/orchestrator.py` 가 순서대로 실행.

| 단계 | 코드 | 외부 도구 | 출력 |
|------|------|-----------|------|
| 1. extract_frames | `stages/extract_frames.py` | ffmpeg | `images/*.jpg` |
| 2. filter_quality | `stages/filter_quality.py` | OpenCV, imagehash | `images/*.jpg` (블러·중복 제거, 다운스케일) |
| 3. colmap_sfm | `stages/colmap_sfm.py` | COLMAP `feature_extractor/sequential_matcher/mapper` | `sparse/0/` |
| 4. colmap_mvs | `stages/colmap_mvs.py` | COLMAP `image_undistorter/patch_match_stereo/stereo_fusion` | `dense/fused.ply` |
| 5. gaussian_splat | `stages/gaussian_splat.py` | graphdeco-inria/gaussian-splatting `train.py` | `gaussian/point_cloud/iteration_*/point_cloud.ply` |
| 6. to_3dtiles | `stages/to_3dtiles.py` | `py3dtiles convert` | `tiles/tileset.json` + b3dm/pnts 타일 |

## 튜닝 포인트

- `PIPELINE_FRAME_FPS` (기본 3): 영상 샘플링 FPS. 도시 산책이면 2, 고속 촬영이면 5까지 올림.
- `PIPELINE_BLUR_THRESHOLD` (기본 60): Laplacian 분산 임계. 실내는 낮춰야 살아남는 프레임이 있음.
- `PIPELINE_MAX_IMAGE_DIM` (기본 1600): COLMAP에 넘기기 전 긴 변 최대 픽셀. 4K는 1600~2400 권장.
- `PIPELINE_GS_ITERATIONS` (기본 30000): 3DGS 학습 반복. 작은 장면은 7000으로도 충분.
- `matcher` 인자: 영상 중심이면 `sequential`, 사진만 뿌려져 있으면 `exhaustive`.

## 지오참조 (GPS 자동 배치)

- 모바일 앱(`camo`)은 사진마다 **EXIF GPS** 태그를 읽어 업로드 메타데이터에 lat/lon/alt
  를 실어 보냄. 갤러리에서 선택한 사진도 원본 EXIF가 보존돼 있으면 그대로 사용됨.
  실내 촬영이라 GPS 위성 신호가 약한 경우엔 EXIF가 비어있어 자동 배치가 안 되고,
  재구성 자체는 로컬 좌표계로 계속 진행됨.
- 워커가 자산 행에서 `(lat, lon, altitude)`를 꺼내 `{filename → (lat, lon, alt)}`
  맵을 만들고, 오케스트레이터는 `pyproj`로 **ECEF 좌표로 환산**해 COLMAP
  `model_aligner`에 `image_name x y z` CSV로 전달.
- 최소 3장 이상 GPS가 있을 때만 alignment 시도 (`MIN_GEO_REFERENCES`). 그 미만이면
  로컬 좌표로 fallback.
- alignment 성공 시 `Reconstruction` 행의 `center_lat/lon/alt/radius_m`가 실제 지구
  좌표계 값으로 채워져 Cesium 뷰어가 지구본 위 해당 위치로 `flyTo` + 핀 드롭.
- 정밀 정합(지상제어점, 시각 장소 인식)은 2차.

## 실내/실외 촬영 모두 지원

- `colmap_sfm.run(..., scene_hint=...)` 에 `"outdoor"` / `"indoor"` / `"auto"` 전달.
- **outdoor preset**: COLMAP 기본값. 고해상도 풍부한 텍스처 전제.
- **indoor preset**: SIFT peak threshold 낮추고 edge threshold 올려 **민무늬 벽에서도
  특징점을 더 많이 추출**. Mapper 초기화 임계도 완화해 짧은 트랙으로도 모델이 시작
  가능. `max_num_features` 두 배.
- **auto**: outdoor로 먼저 시도하고 mapper가 모델을 못 만들면 **indoor preset으로 자동
  재시도** (새 database.db, 새 sparse_retry 디렉토리). 일반 사용자는 이 모드만 쓰면 됨.

## 워커

- `worker.py::run_reconstruction(capture_id, job_id)` 가 RQ 태스크.
- 단계 전환 시 `on_stage` 콜백이 `jobs.stage` 컬럼을 업데이트 → API `/captures/{id}/jobs` 로
  진행률을 알 수 있음.
- 실패 시 예외 메시지를 `jobs.error` 에 저장하고 status를 `failed` 로 전환.
