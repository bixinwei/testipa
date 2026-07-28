# HelloIPA

一个采用 iPhone 4S 时代备忘录视觉风格、并保留局域网文本分享能力的 iOS 工程。

当前功能：
- 备忘录列表：新建、查看、切换和删除本地备忘录
- 黄纸横线、皮革导航栏和底部工具栏的拟物化编辑界面
- 可用上一条/下一条按钮浏览备忘录
- 点击局域网分享按钮后，手机会为当前备忘录启动 HTTP 服务
- App 会弹出一个类似 `http://192.168.x.x:8080` 的地址
- 同一 Wi-Fi 下的电脑打开这个地址后，可以看到并编辑这段文本
- 网页点击 `同步到手机` 后，网页里的文本会回写到当前备忘录
- 旧版本保存的单段文本会在首次启动时自动迁移为第一条备忘录

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
