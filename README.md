# HelloIPA

一个只保留“局域网文本分享”功能的 iOS 工程。

当前功能：
- App 内可以编辑和预览一段文本
- 点击 `分享文本` 后，手机会启动一个局域网 HTTP 服务
- App 会弹出一个类似 `http://192.168.x.x:8080` 的地址
- 同一 Wi-Fi 下的电脑打开这个地址后，可以看到并编辑这段文本
- 网页点击 `同步到手机` 后，网页里的文本会回写到手机 App

构建相关文件：
- `.github/workflows/build-ios-unsigned.yml`
- `scripts/build_unsigned_ipa.sh`
- `HelloIPA.xcodeproj/xcshareddata/xcschemes/HelloIPA.xcscheme`

GitHub Actions 使用方式：
1. 把整个 `HelloIPAProject` 上传到 GitHub 仓库根目录。
2. 推送到 `main` 或 `master`，或者手动触发 Actions。
3. 等待 `Build Unsigned iOS IPA` 完成。
4. 下载产物 `HelloIPA-unsigned`。
5. 产物中只包含 `HelloIPA.ipa`。

工作流行为：
- 使用 GitHub 的 macOS runner
- 构建未签名的 `HelloIPA.app`
- 打包成 `HelloIPA.ipa`

注意：
- 这是未签名 IPA，不适用于常规 App Store 安装流程。
- 当前本地环境没有 Xcode，所以这里只维护工程文件，实际 IPA 依赖 GitHub Actions 或 macOS + Xcode 构建。

Bundle identifier：
- `com.example.helloipa`
