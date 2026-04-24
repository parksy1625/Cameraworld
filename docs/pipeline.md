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

## 지오참조 (1차)

- COLMAP 내부 좌표계는 임의 스케일/원점. `align_to_geo()`는 `image_name,x,y,z` ECEF CSV를
  `model_aligner`에 전달한다.
- 1차는 모바일 앱이 첨부한 GPS EXIF를 그대로 CSV로 변환해 사용. 정밀도 ±5~10m 수준.
- 정밀 정합(지상제어점, 시각 장소 인식)은 2차.

## 워커

- `worker.py::run_reconstruction(capture_id, job_id)` 가 RQ 태스크.
- 단계 전환 시 `on_stage` 콜백이 `jobs.stage` 컬럼을 업데이트 → API `/captures/{id}/jobs` 로
  진행률을 알 수 있음.
- 실패 시 예외 메시지를 `jobs.error` 에 저장하고 status를 `failed` 로 전환.
