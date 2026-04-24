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

## 모바일 APK 다운로드

`.github/workflows/apk.yml` 가 푸시·수동 트리거 때마다 Android 릴리스
APK를 빌드합니다. 다운로드 경로 2가지:

1. **GitHub Actions artifact** — GitHub 저장소 → Actions → 해당 workflow run
   → `camo-release-apk` zip 내려받기 (로그인 필요).
2. **GitHub Release** — `v0.1.0` 처럼 `v*` 태그를 푸시하면 워크플로가
   Release에 APK를 자동 첨부합니다. Release 페이지에서 바로 다운로드
   가능 (로그인 불필요, 폰 브라우저로 접근 가능).

설치:
- Android 설정에서 "출처를 알 수 없는 앱 설치" 허용
- 내려받은 apk 탭 → 설치
- 기본은 **로컬 테스트 모드**라서 백엔드 없이도 업로드 / 3D 뷰까지 동작

## 라이선스
MIT (LICENSE 참조)
