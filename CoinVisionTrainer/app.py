"""Local coin detector dataset annotator and verifier for Windows."""
from __future__ import annotations
import json, shutil, threading
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

try:
    from PIL import Image, ImageTk
except ImportError:
    Image = ImageTk = None

ROOT = Path(__file__).resolve().parent
WORK = ROOT / "workspace"
IMAGES = WORK / "images"
LABELS = WORK / "labels"
MODEL_DIR = WORK / "runs"
for p in (IMAGES, LABELS, MODEL_DIR): p.mkdir(parents=True, exist_ok=True)

class App:
    def __init__(self, root: tk.Tk):
        self.root = root; root.title("Coin Vision Trainer"); root.geometry("1100x760")
        self.files: list[Path] = []; self.index = -1; self.photo = None
        self.boxes: list[tuple[int,int,int,int]] = []; self.start = None; self.preview_scale = 1.0
        self._build_ui()

    def _build_ui(self):
        bar = ttk.Frame(self.root, padding=8); bar.pack(fill="x")
        for text, cmd in [("导入样本", self.import_samples), ("保存当前标注", self.save_label),
                          ("训练 YOLOv8n", self.train), ("验证新图片", self.verify)]:
            ttk.Button(bar, text=text, command=cmd).pack(side="left", padx=4)
        self.status = ttk.Label(bar, text="先导入样本图片"); self.status.pack(side="left", padx=16)
        body = ttk.PanedWindow(self.root, orient="horizontal"); body.pack(fill="both", expand=True, padx=8, pady=8)
        left = ttk.Frame(body); body.add(left, weight=1)
        self.listbox = tk.Listbox(left, width=32); self.listbox.pack(fill="both", expand=True)
        self.listbox.bind("<<ListboxSelect>>", lambda e: self.select(self.listbox.curselection()[0]))
        right = ttk.Frame(body); body.add(right, weight=4)
        self.canvas = tk.Canvas(right, bg="#202020", highlightthickness=0); self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<ButtonPress-1>", self.begin_box); self.canvas.bind("<B1-Motion>", self.drag_box); self.canvas.bind("<ButtonRelease-1>", self.end_box)
        ttk.Label(right, text="拖动鼠标框选金币；一张图可标多个框。保存后进入下一张。", padding=6).pack(fill="x")

    def import_samples(self):
        if Image is None: return messagebox.showerror("缺少依赖", "请先运行: py -m pip install pillow")
        paths = filedialog.askopenfilenames(title="选择金币样本", filetypes=[("Images", "*.png *.jpg *.jpeg *.bmp")])
        for src in paths:
            dst = IMAGES / Path(src).name
            if Path(src).resolve() != dst.resolve(): shutil.copy2(src, dst)
            if dst not in self.files: self.files.append(dst); self.listbox.insert("end", dst.name)
        if self.files and self.index < 0: self.select(0)
        self.status.config(text=f"已导入 {len(self.files)} 张样本")

    def select(self, i):
        if i < 0 or i >= len(self.files): return
        self.index = i; self.boxes = []; self.start = None
        label = LABELS / (self.files[i].stem + ".txt")
        try:
            with Image.open(self.files[i]) as im: w,h=im.size
            if label.exists():
                for line in label.read_text().splitlines():
                    _, cx, cy, bw, bh = map(float, line.split()); self.boxes.append((int((cx-bw/2)*w), int((cy-bh/2)*h), int((cx+bw/2)*w), int((cy+bh/2)*h)))
        except Exception as e: return self.status.config(text=f"读取失败: {e}")
        self.show()

    def show(self):
        if Image is None: return
        try: im=Image.open(self.files[self.index]).convert("RGB")
        except Exception: return
        cw=max(1,self.canvas.winfo_width()); ch=max(1,self.canvas.winfo_height()); self.preview_scale=min(cw/im.width,ch/im.height,1.0)
        view=im.resize((int(im.width*self.preview_scale),int(im.height*self.preview_scale)), Image.Resampling.LANCZOS)
        self.photo=ImageTk.PhotoImage(view); self.canvas.delete("all"); self.canvas.create_image(0,0,anchor="nw",image=self.photo)
        for x1,y1,x2,y2 in self.boxes: self.canvas.create_rectangle(x1*self.preview_scale,y1*self.preview_scale,x2*self.preview_scale,y2*self.preview_scale,outline="red",width=3)

    def begin_box(self,e): self.start=(e.x/self.preview_scale,e.y/self.preview_scale); self.temp=self.canvas.create_rectangle(e.x,e.y,e.x,e.y,outline="red",width=3)
    def drag_box(self,e):
        if self.start: self.canvas.coords(self.temp,self.start[0]*self.preview_scale,self.start[1]*self.preview_scale,e.x,e.y)
    def end_box(self,e):
        if not self.start: return
        x1,y1=self.start; x2,y2=e.x/self.preview_scale,e.y/self.preview_scale; self.start=None; self.canvas.delete(self.temp)
        if abs(x2-x1)>4 and abs(y2-y1)>4: self.boxes.append((int(min(x1,x2)),int(min(y1,y2)),int(max(x1,x2)),int(max(y1,y2)))); self.show()

    def save_label(self):
        if self.index < 0: return
        with Image.open(self.files[self.index]) as im: w,h=im.size
        lines=[]
        for x1,y1,x2,y2 in self.boxes: lines.append(f"0 {(x1+x2)/2/w:.6f} {(y1+y2)/2/h:.6f} {(x2-x1)/w:.6f} {(y2-y1)/h:.6f}")
        (LABELS/(self.files[self.index].stem+".txt")).write_text("\n".join(lines),encoding="utf-8"); self.status.config(text=f"已保存 {len(lines)} 个金币框")

    def train(self):
        if len(self.files)<2: return messagebox.showinfo("样本不足", "至少标注两张图片后再训练")
        for p in self.files:
            if not (LABELS/(p.stem+".txt")).exists(): return messagebox.showwarning("还有未标注图片", p.name)
        try: import yaml
        except ImportError: return messagebox.showerror("缺少依赖", "请先运行: py -m pip install ultralytics pillow")
        data=WORK/"coin.yaml"; data.write_text(yaml.safe_dump({"path":str(WORK),"train":"images","val":"images","names":{0:"coin"}},allow_unicode=True),encoding="utf-8")
        def run():
            try:
                from ultralytics import YOLO
                model=YOLO("yolov8n.pt"); model.train(data=str(data),epochs=30,imgsz=640,project=str(MODEL_DIR),name="coin",exist_ok=True)
                self.root.after(0,lambda:self.status.config(text="训练完成，可验证新图片"))
            except Exception as e: self.root.after(0,lambda:messagebox.showerror("训练失败",str(e)))
        self.status.config(text="训练中，首次可能下载模型…"); threading.Thread(target=run,daemon=True).start()

    def verify(self):
        path=filedialog.askopenfilename(title="选择验证图片",filetypes=[("Images","*.png *.jpg *.jpeg *.bmp")]);
        if not path: return
        best=MODEL_DIR/"coin"/"weights"/"best.pt"
        if not best.exists(): return messagebox.showinfo("尚未训练", "请先完成样本标注并训练模型")
        def run():
            try:
                from ultralytics import YOLO
                r=YOLO(str(best))(path,conf=.35,verbose=False)[0]; out=Path(path).with_name(Path(path).stem+"_pred.jpg"); r.save(filename=str(out))
                self.root.after(0,lambda: (self.status.config(text=f"识别到 {len(r.boxes)} 个金币，结果: {out.name}"), self.open_result(out)))
            except Exception as e: self.root.after(0,lambda:messagebox.showerror("识别失败",str(e)))
        self.status.config(text="识别中…"); threading.Thread(target=run,daemon=True).start()

    def open_result(self,p):
        self.files.append(p); self.listbox.insert("end",p.name); self.select(len(self.files)-1)

if __name__ == "__main__":
    root=tk.Tk(); App(root); root.mainloop()
