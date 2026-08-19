# Signal Relay 신호설비 YOLO 학습 규격

## 데이터 구조
`dataset.yaml`의 20개 클래스를 그대로 유지합니다. 사진은 train/val/test로 분리하고 각 이미지에 Ultralytics YOLO detection 형식의 라벨을 둡니다.

## 권장 원칙
- 설비 전체 박스와 이상 외관 박스를 동시에 라벨링합니다.
- `파손`, `이탈`, `케이블노출`, `부식`, `잡초`, `침수`, `이물질`은 사진에서 육안으로 식별 가능한 경우에만 라벨링합니다.
- 전압 이상, 회로 불량, 쇄정 불량처럼 사진만으로 판단할 수 없는 상태는 학습 클래스에 넣지 않습니다.
- 다양한 거리, 야간, 역광, 우천, 오염, 흔들림 사진을 포함합니다.
- 동일 장소 연속촬영 사진이 train/val 양쪽에 섞이지 않도록 촬영 세션 단위로 분리합니다.

## 학습 예시
```bash
yolo detect train data=dataset.yaml model=yolo11n.pt imgsz=640 epochs=150 batch=16
```

## ONNX 규격
- 입력: float32 `[1,3,640,640]`
- RGB, 0~1 정규화
- 검은색 letterbox
- 출력: raw detection `[1,4+nc,N]` 또는 `[1,N,4+nc]`
- 좌표: `cx, cy, width, height`
- 클래스 점수: index 4부터
- NMS는 모델 밖, Android 앱에서 수행

`export_model.py`로 내보낸 뒤 앱 설정에서 `.onnx` 파일을 설치합니다.
