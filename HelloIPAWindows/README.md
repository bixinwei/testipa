# HelloIPA Windows

这是 `HelloIPA` iOS 备忘录的独立 Windows 移植项目，使用 Electron + 原生 HTML/CSS/JavaScript，完整复用 `HelloIPA/Resources` 中的 OldOS 纸张、皮革顶栏和按钮素材。

## 功能

- 备忘录列表、新建、任意位置进入详情
- 文本编辑、自动保存、前后备忘录切换、删除
- Today/日期时间、OldOS 黄纸横线、底部工具栏
- 局域网 HTTP 分享：Windows 浏览器访问地址并把文本同步回应用
- 数据保存到 Electron `userData/notes.json`

## 运行源码

安装 Node.js 18+ 后在本目录执行：

```powershell
npm install
npm start
```

不要直接双击 `renderer.html`；它只是渲染资源，脱离 Electron 会出现黑屏或无法使用 IPC。

## 直接运行 EXE

已生成便携版：`HelloIPAWindows.exe`（项目上级目录也有一份）。双击 EXE 即可运行，不需要打开 HTML，也不需要安装 Node.js。

Windows 安装包可在此基础上接入 electron-builder；本项目不改变原 iOS 工程和素材源文件。
