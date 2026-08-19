# Signal Relay V1.5

철도 신호설비 미조치 사항을 사진 + GPS + 온디바이스 Vision AI로 기록하고 다음 조에 인계하는 Android 앱입니다.

## 핵심 기능
- 완전 오프라인 현장 기록
- Android Native ONNX Runtime
- NNAPI 우선 / CPU 폴백
- 카메라 촬영 및 사진 기록
- GPS 위치 저장 및 오프라인 플롯 지도
- 미조치 → 작업중 → 조치완료 흐름
- 신호설비 전용 YOLO ONNX 모델 설치
- 글래스모피즘 모바일 UI

## AI 모델 규격
입력은 RGB float32 `[1,3,640,640]`이며 출력은 raw YOLO detection `[1,4+nc,N]` 또는 `[1,N,4+nc]`을 지원합니다. 자세한 내용은 `model-training/` 폴더를 참고하세요.

## APK 자동 빌드
GitHub Actions의 `Build Signal Relay APK` 워크플로가 `main` 브랜치 push 시 Debug APK를 자동 빌드합니다.

산출물: `SignalRelay-v1.5-debug-apk`
