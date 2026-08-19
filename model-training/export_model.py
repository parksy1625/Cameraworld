from ultralytics import YOLO

# 학습 완료 후 best.pt를 640x640 고정 입력 ONNX로 내보냅니다.
model = YOLO("runs/detect/train/weights/best.pt")
model.export(format="onnx", imgsz=640, dynamic=False, simplify=True)
print("Export complete. Copy best.onnx to the phone and install it from Signal Relay settings.")
