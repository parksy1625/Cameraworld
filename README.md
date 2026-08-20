# Signal Relay V1.6

철도 신호설비 미조치 사항을 사진 + GPS + 온디바이스 Vision AI로 기록하고 다음 조에 인계하는 Android 앱입니다.

## V1.6 구조
- 기록·사진·GPS·상태: 온라인 공유(Supabase)
- 인터넷 끊김: 로컬 저장 + 업로드 대기열
- 온라인 복귀: 자동 동기화
- Vision AI: Android Native ONNX Runtime으로 기기 내부 처리
- AI 분석을 위해 사진을 외부 AI API로 보내지 않음
- 같은 워크스페이스를 사용하는 여러 휴대폰 간 기록 공유

## 서버 설정
1. Supabase 프로젝트 생성
2. `supabase/setup.sql` 실행
3. 앱 설정에 Project URL / Anon Key / 워크스페이스 입력

## AI 모델 규격
입력 RGB float32 `[1,3,640,640]`, raw YOLO detection `[1,4+nc,N]` 또는 `[1,N,4+nc]`.

## APK 자동 빌드
GitHub Actions `Build Signal Relay APK`가 Debug APK를 빌드합니다.
산출물: `SignalRelay-v1.6-debug-apk`
