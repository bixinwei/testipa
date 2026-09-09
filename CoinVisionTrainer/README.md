# CoinVisionTrainer

Windows 本地金币检测样本标注与验证工具。使用 Tkinter 做界面，训练/推理使用 Ultralytics YOLO（推荐 `yolov8n.pt`）。

## 运行

```powershell
py -m pip install ultralytics pillow
py app.py
```

操作顺序：导入样本 → 在画布上拖出金币红框 → 保存标注 → 重复处理样本 → 训练模型 → 导入验证图片。

标注和模型都保存在本项目的 `workspace` 目录，不会上传图片。
