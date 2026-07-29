# HelloIPA Windows Native

原生 Win32/GDI+ Windows 版本，不依赖 Electron、Chromium、Node.js 或 ffmpeg.dll。复用 `HelloIPAWindows/assets` 中的全部 OldOS 图片素材。

已编译的原生程序：`HelloIPAWindowsNative.exe`。它只依赖 Windows 系统 DLL 和本目录 `assets` 素材，不需要 Electron、Node.js、Chromium 或 ffmpeg.dll。

使用 CMake + MinGW 或 Visual Studio 编译：

```powershell
cmake -S . -B build -G "MinGW Makefiles"
cmake --build build --config Release
```
