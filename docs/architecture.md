# Cameraworld — Architecture (1차 MVP)

## 데이터 흐름

```
┌──────────────┐      ┌──────────────┐      ┌──────────────────┐
│ Flutter app  │──────▶ FastAPI API  │──────▶ MinIO (captures) │
│  capture     │      │  /captures   │      └──────────────────┘
└──────────────┘      └──────┬───────┘              ▲
                             │                      │ presigned PUT
                             ▼                      │
                      ┌──────────────┐              │
                      │ Postgres     │              │
                      │ jobs/assets  │              │
                      └──────┬───────┘              │
                             │                      │
                             ▼                      │
                      ┌──────────────┐              │
                      │ Redis (RQ)   │              │
                      └──────┬───────┘              │
                             │                      │
                             ▼                      │
                  ┌────────────────────────────────┐│
                  │ Pipeline worker (GPU)          ││
                  │  extract → filter → SfM → MVS  ││
                  │  → Gaussian Splats → 3D Tiles  ││
                  └──────┬─────────────────────────┘│
                         │                          │
                         ▼                          │
                  ┌──────────────────┐              │
                  │ MinIO (artifacts)│──────────────┘
                  └──────┬───────────┘
                         │ signed GET
                         ▼
                  ┌──────────────────┐
                  │ CesiumJS viewer  │
                  │  3D Tiles +      │
                  │  Splat overlay   │
                  └──────────────────┘
```

## 컴포넌트 책임

| 컴포넌트 | 담당 |
|----------|------|
| Flutter 앱 | 카메라+GPS 캡처, 촬영 가이드, 청크 업로드 |
| FastAPI | 캡처/자산 CRUD, presigned URL 발급, RQ로 작업 큐잉, 재구성 메타 조회 |
| Postgres | 정규화된 메타(captures/assets/jobs/reconstructions) |
| Redis + RQ | 워커 큐, RQ job id로 추적 |
| MinIO | 원본 캡처 버킷 + 산출물 버킷(타일·splat·점군) |
| Pipeline | orchestrator가 6단계를 순서대로 실행; COLMAP/FFmpeg/py3dtiles CLI 래핑 |
| Viewer | CesiumJS 지구본에 3D Tiles 로드, three.js로 Splat 오버레이 합성 |

## 저장소 스키마 (핵심 컬럼)

- `captures(id, region_id, user_id, lat/lon bbox, created_at, submitted_at)`
- `assets(id, capture_id, kind, storage_key, content_type, size_bytes, gps, captured_at)`
- `jobs(id, capture_id, status, stage, error, rq_job_id, timestamps)`
- `reconstructions(id, capture_id, job_id, tileset_key, splat_key, pointcloud_key, center_lat/lon/alt, radius_m)`

## 1차 범위

단일 구역 프로토타입: 공원/광장/건물 한 블록 수준. 촬영 → 업로드 → COLMAP
+ 3D Gaussian Splatting → Cesium 표시까지 end-to-end 검증.

## 2차 이후

- 다수 사용자 재구성 정합/병합(ICP, 시각 기반 장소 인식)
- 도시 규모 스트리밍과 LOD 자동 관리
- 온디바이스 SLAM / 실시간 캡처
- 얼굴·번호판 자동 블러 (공개 서비스화 전 필수)
