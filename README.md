# Cameraworld

크라우드소싱된 2D 사진·영상으로 실세계 구역의 3D 지도를 자동 생성하는 플랫폼.

## 구성 요소

| 디렉토리 | 설명 |
|----------|------|
| `mobile/` | **camo** — Flutter 앱 단일 파일 (탭1: 업로드 · 탭2: 3D 지도) |
| `backend/` | FastAPI — 업로드·작업·자산 관리 |
| `pipeline/` | GPU 워커 — COLMAP SfM/MVS + 3D Gaussian Splatting |
| `viewer/` | CesiumJS 웹 뷰어 (3D Tiles + Gaussian Splat 오버레이) |
| `infra/` | docker-compose 로컬 스택 |
| `docs/` | 촬영 가이드, 파이프라인 상세, 아키텍처 |

## 빠른 시작

```bash
cp .env.example .env
make up              # postgres + redis + minio + api + worker
make pipeline-smoke  # 샘플 캡처 end-to-end
make viewer          # 뷰어 (http://localhost:5173)
```

자세한 내용은 `docs/architecture.md` 참고.

## 라이선스
MIT (LICENSE 참조)
