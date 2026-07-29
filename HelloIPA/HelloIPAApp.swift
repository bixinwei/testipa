import SwiftUI
import Network
import Foundation
import Darwin
import UIKit
import Combine

enum AppDefaults {
    static let savedTextKey = "helloipa.savedText"
    static let notesKey = "helloipa.notes"
    static let initialText = """
    这是一段示例文本。
    点击“分享文本”后，局域网内的电脑打开地址即可看到它。
    """
}

private extension Color {
    static let retroLeatherDark = Color(red: 0.32, green: 0.20, blue: 0.12)
    static let retroLeatherLight = Color(red: 0.56, green: 0.38, blue: 0.23)
    // Match the warm ivory paper and muted graphite rules of the original Notes app.
    static let retroPaper = Color(red: 1.00, green: 0.99, blue: 0.82)
    static let retroPaperLine = Color(red: 0.60, green: 0.56, blue: 0.37)
    static let retroPaperMargin = Color(red: 0.47, green: 0.32, blue: 0.18)
    static let retroMetadata = Color(red: 0.49, green: 0.29, blue: 0.17)
    static let retroWoodDark = Color(red: 0.16, green: 0.10, blue: 0.06)
    static let retroWoodLight = Color(red: 0.24, green: 0.15, blue: 0.09)
    static let retroLCDBackground = Color(red: 0.05, green: 0.09, blue: 0.06)
    static let retroLCDText = Color(red: 0.55, green: 0.95, blue: 0.55)
}

/// OldOS artwork is copied into the app bundle as regular PNG files, not an
/// asset catalog. Resolve the concrete file path on device.
private func oldOSImage(named name: String) -> Image? {
    guard let path = Bundle.main.path(forResource: name, ofType: "png"),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let image = UIImage(data: data, scale: 2) else {
        return nil
    }
    return Image(uiImage: image)
}

/// Glossy capsule button in the style of pre-iOS7 default UIButtons: top highlight sheen + bevel border.
struct GlossyCapsuleButtonStyle: ButtonStyle {
    let baseColor: Color
    var fontSize: CGFloat = 17

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(.white)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [baseColor.opacity(0.95), baseColor.opacity(0.68)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.4), lineWidth: 1)
                }
                .opacity(configuration.isPressed ? 0.72 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .shadow(
                color: Color.black.opacity(0.35),
                radius: configuration.isPressed ? 1 : 4,
                x: 0,
                y: configuration.isPressed ? 1 : 3
            )
    }
}

/// The Notes header controls use the stretchable dark center artwork. Keeping
/// every control rectangular makes the list and editor title bars share one
/// continuous silhouette.
struct OldOSHeaderControl: View {
    let title: String?
    let iconName: String?

    var body: some View {
        ZStack {
            if let buttonCenter = oldOSImage(named: "oldos-notes-button-center") {
                buttonCenter
                    .resizable(
                        capInsets: EdgeInsets(top: 10, leading: 5, bottom: 10, trailing: 5),
                        resizingMode: .stretch
                    )
            }

            if let title = title {
                // The original Notes return button has a distinct rounded left
                // cap and arrow; the stretchable center alone looks rectangular.
                if let backCap = oldOSImage(named: "oldos-notes-back") {
                    backCap
                        .renderingMode(.original)
                        .resizable()
                        .frame(width: 19, height: 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let arrow = oldOSImage(named: "oldos-notes-back-arrow") {
                    arrow
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 11, height: 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 5)
                }

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.7), radius: 0, x: 0, y: 1)
                    .padding(.leading, 10)
            }

            if let iconName = iconName {
                if let icon = oldOSImage(named: iconName) {
                    icon
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 17)
                }
            }
        }
        .frame(height: 30)
    }
}

/// Leather-textured top bar echoing the iOS 6 Notes/Contacts chrome.
struct RetroTitleBar<Trailing: View>: View {
    let title: String
    let truncatesTitle: Bool
    let leading: AnyView?
    let trailing: () -> Trailing

    init(
        title: String,
        truncatesTitle: Bool = false,
        leading: AnyView? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.truncatesTitle = truncatesTitle
        self.leading = leading
        self.trailing = trailing
    }

    /// Classic Notes only had room for a short, centered title.  Do the truncation
    /// deliberately so long Chinese titles behave the same as long Latin titles.
    private var displayTitle: String {
        guard truncatesTitle else { return title }
        let characters = Array(title)
        guard characters.count > 8 else { return title }
        return String(characters.prefix(8)) + "…"
    }

    var body: some View {
        ZStack {
            if let topBar = oldOSImage(named: "oldos-notes-topbar") {
                topBar
                    .resizable()
                    .scaledToFill()
                    .clipped()
            }

            VStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1)
                Spacer()
                Rectangle().fill(Color.black.opacity(0.34)).frame(height: 1)
            }

            Text(displayTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color.white.opacity(0.95))
                .shadow(color: Color.black.opacity(0.6), radius: 0, x: 0, y: 1)
                .lineLimit(1)

            if let leading = leading {
                leading
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 14)
            }

            trailing()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
        }
        .frame(height: 52)
        .background(
            LinearGradient(
                colors: [Color.retroLeatherLight, Color.retroLeatherDark],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

/// Yellow ruled legal-pad background, à la the original iOS Notes app.
struct RuledPaperBackground: View {
    var lineOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Keep an opaque light paper behind the texture in every
                // appearance mode, including if a bundled image is unavailable.
                Color.retroPaper

                if let paper = oldOSImage(named: "oldos-notes-body") {
                    paper
                        .resizable()
                        .scaledToFill()
                        .clipped()
                }

                Path { path in
                    let phase = lineOffset.truncatingRemainder(dividingBy: 26)
                    var y: CGFloat = 30 - phase
                    while y > 0 { y -= 26 }
                    while y < geometry.size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        y += 26
                    }
                }
                .stroke(Color.retroPaperLine.opacity(0.70), lineWidth: 1)

                Path { path in
                    path.move(to: CGPoint(x: 30, y: 0))
                    path.addLine(to: CGPoint(x: 30, y: geometry.size.height))
                }
                .stroke(Color.retroPaperMargin.opacity(0.7), lineWidth: 1.4)
            }
        }
    }
}

struct ActivityIndicator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        return indicator
    }

    func updateUIView(_ uiView: UIActivityIndicatorView, context: Context) {
    }
}

struct StableTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var scrollOffset: CGFloat

    // Match the handwritten face used for each title in the Notes list.
    private static let noteFont = UIFont(name: "MarkerFelt-Wide", size: 16) ?? .systemFont(ofSize: 16, weight: .semibold)
    private static let noteTextColor = UIColor(red: 0.10, green: 0.07, blue: 0.04, alpha: 1)
    private static let noteLineHeight: CGFloat = 26

    private static func noteAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = noteLineHeight
        paragraphStyle.maximumLineHeight = noteLineHeight
        paragraphStyle.lineBreakMode = .byWordWrapping

        return [
            .font: noteFont,
            .foregroundColor: noteTextColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    private static func styledText(_ value: String) -> NSAttributedString {
        let styled = NSMutableAttributedString(string: value, attributes: noteAttributes())
        let fullRange = NSRange(value.startIndex..., in: value)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        detector?.enumerateMatches(in: value, options: [], range: fullRange) { match, _, _ in
            guard let match = match, let url = match.url else { return }
            styled.addAttributes([
                .link: url,
                .foregroundColor: UIColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
        return styled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, scrollOffset: $scrollOffset)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        // A transparent UIKit view must not declare itself opaque. Otherwise the
        // compositor is allowed to substitute a black backing store in Dark Mode.
        textView.isOpaque = false
        textView.backgroundColor = .clear
        textView.overrideUserInterfaceStyle = .light
        textView.textColor = Self.noteTextColor
        textView.font = Self.noteFont
        textView.typingAttributes = Self.noteAttributes()
        textView.isSelectable = true
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.contentInset = .zero
        textView.scrollIndicatorInsets = .zero
        // Shift each glyph run down by half the remaining leading so it sits
        // in the middle of its 26pt ruled-paper row rather than on a rule.
        textView.textContainerInset = UIEdgeInsets(top: 13, left: 10, bottom: 14, right: 10)
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.attributedText = Self.styledText(text)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // Keep the paper visible when the device changes appearance while the
        // editor is on screen.
        textView.isOpaque = false
        textView.backgroundColor = .clear
        textView.overrideUserInterfaceStyle = .light
        guard textView.text != text else { return }

        let selectedRange = textView.selectedRange
        textView.attributedText = Self.styledText(text)
        textView.typingAttributes = Self.noteAttributes()
        let clampedLocation = min(selectedRange.location, (textView.text as NSString).length)
        textView.selectedRange = NSRange(location: clampedLocation, length: 0)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var scrollOffset: CGFloat

        init(text: Binding<String>, scrollOffset: Binding<CGFloat>) {
            _text = text
            _scrollOffset = scrollOffset
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            let selectedRange = textView.selectedRange
            textView.attributedText = StableTextEditor.styledText(textView.text)
            textView.typingAttributes = StableTextEditor.noteAttributes()
            textView.selectedRange = selectedRange
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Preserve negative overscroll as well: while the user pulls the
            // document down from its top edge, the ruled paper must travel
            // down with its text rather than remaining fixed behind it.
            scrollOffset = scrollView.contentOffset.y
        }

        func textView(_ textView: UITextView,
                      shouldInteractWith URL: URL,
                      in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            UIApplication.shared.open(URL)
            return false
        }
    }
}

final class LocalTextShareServer: ObservableObject {
    @Published private(set) var shareURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSharingEnabled = false
    @Published private(set) var syncedText: String

    private let queue = DispatchQueue(label: "helloipa.local-text-server")
    private let preferredPorts: [UInt16] = [8080, 8081, 8082, 8090]
    private let maxRequestSize = 1_048_576
    private var listener: NWListener?
    private var currentText: String
    private var currentPort: UInt16?
    private var nextPortIndex = 0

    init(initialText: String = AppDefaults.initialText) {
        self.syncedText = initialText
        self.currentText = initialText
    }

    func updateSharedText(_ text: String) {
        queue.async {
            self.currentText = text
        }
        DispatchQueue.main.async {
            if self.syncedText != text {
                self.syncedText = text
            }
        }
    }

    func startSharing(text: String) {
        updateSharedText(text)
        DispatchQueue.main.async {
            self.errorMessage = nil
            self.isSharingEnabled = true
        }

        if listener != nil {
            return
        }

        nextPortIndex = 0
        tryNextPort()
    }

    func stopSharing() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.currentPort = nil
            self.nextPortIndex = 0
        }

        DispatchQueue.main.async {
            self.shareURL = nil
            self.errorMessage = nil
            self.isSharingEnabled = false
        }
    }

    private func startListener(on port: UInt16) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, port: port)
            }

            self.listener = listener
            self.currentPort = port
            listener.start(queue: queue)
            return true
        } catch {
            return false
        }
    }

    private func handleListenerState(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            currentPort = port
            DispatchQueue.main.async {
                self.errorMessage = nil
            }
            publishShareURL()
        case .failed(let error):
            listener?.cancel()
            listener = nil
            currentPort = nil

            if nextPortIndex < preferredPorts.count {
                tryNextPort()
            } else {
                DispatchQueue.main.async {
                    self.shareURL = nil
                    self.errorMessage = error.localizedDescription
                    self.isSharingEnabled = false
                }
            }
        default:
            break
        }
    }

    private func tryNextPort() {
        guard nextPortIndex < preferredPorts.count else {
            DispatchQueue.main.async {
                self.errorMessage = "无法启动 HTTP 分享服务，请稍后重试。"
                self.shareURL = nil
                self.isSharingEnabled = false
            }
            return
        }

        let port = preferredPorts[nextPortIndex]
        nextPortIndex += 1

        if !startListener(on: port) {
            tryNextPort()
        }
    }

    private func publishShareURL() {
        guard let port = currentPort else {
            DispatchQueue.main.async {
                self.shareURL = nil
                self.errorMessage = "分享服务端口不可用。"
            }
            return
        }

        guard let address = Self.localIPv4Address() else {
            DispatchQueue.main.async {
                self.shareURL = nil
                self.errorMessage = "未检测到可用于局域网访问的 IPv4 地址，请确认手机已连接 Wi-Fi。"
            }
            return
        }

        DispatchQueue.main.async {
            self.errorMessage = nil
            self.shareURL = URL(string: "http://\(address):\(port)")
        }
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(on: connection)
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest(on connection: NWConnection) {
        receiveRequestData(on: connection, accumulatedData: Data())
    }

    private func receiveRequestData(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            var buffer = accumulatedData
            if let data = data, !data.isEmpty {
                buffer.append(data)
            }

            if buffer.count > self.maxRequestSize {
                let body = "{\"ok\":false,\"error\":\"文本过长，单次同步内容不能超过 1 MB。\"}"
                let response = self.httpResponse(
                    statusLine: "HTTP/1.1 413 Payload Too Large\r\n",
                    contentType: "application/json; charset=utf-8",
                    body: body
                )
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            if let request = Self.parseCompleteRequest(from: buffer) {
                let response: String

                if request.requestLine.hasPrefix("GET "), request.path == "/" {
                    let body = self.makeHTMLPage(with: self.currentText)
                    response = self.httpResponse(
                        statusLine: "HTTP/1.1 200 OK\r\n",
                        contentType: "text/html; charset=utf-8",
                        body: body
                    )
                } else if request.requestLine.hasPrefix("POST "), request.path == "/sync" {
                    self.updateSharedText(request.body)
                    let body = "{\"ok\":true}"
                    response = self.httpResponse(
                        statusLine: "HTTP/1.1 200 OK\r\n",
                        contentType: "application/json; charset=utf-8",
                        body: body
                    )
                } else {
                    let body = "<html><body><h1>404</h1></body></html>"
                    response = self.httpResponse(
                        statusLine: "HTTP/1.1 404 Not Found\r\n",
                        contentType: "text/html; charset=utf-8",
                        body: body
                    )
                }

                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receiveRequestData(on: connection, accumulatedData: buffer)
        }
    }

    private func httpResponse(statusLine: String, contentType: String, body: String) -> String {
        statusLine
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
            + body
    }

    private func makeHTMLPage(with text: String) -> String {
        let escapedText = Self.escapeHTML(text)

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>HelloIPA 文本分享</title>
          <style>
            :root {
              color-scheme: light;
              --bg: #f4f1ea;
              --card: #fffdf8;
              --text: #1f1a14;
              --muted: #786b5d;
              --line: #e5d7c5;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              min-height: 100vh;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background:
                radial-gradient(circle at top left, rgba(214, 177, 114, 0.22), transparent 32%),
                linear-gradient(180deg, #fbf7ef 0%, var(--bg) 100%);
              color: var(--text);
              display: flex;
              align-items: center;
              justify-content: center;
              padding: 24px;
            }
            .card {
              width: min(760px, 100%);
              background: var(--card);
              border: 1px solid var(--line);
              border-radius: 24px;
              padding: 28px;
              box-shadow: 0 24px 60px rgba(70, 48, 21, 0.12);
            }
            .eyebrow {
              margin: 0 0 8px;
              color: var(--muted);
              font-size: 13px;
              letter-spacing: 0.08em;
              text-transform: uppercase;
            }
            h1 {
              margin: 0 0 16px;
              font-size: 28px;
            }
            textarea {
              width: 100%;
              min-height: 260px;
              padding: 16px;
              border-radius: 18px;
              border: 1px solid var(--line);
              background: #fff;
              color: var(--text);
              font: inherit;
              font-size: 17px;
              line-height: 1.6;
              resize: vertical;
            }
            button {
              margin-top: 16px;
              border: 0;
              border-radius: 16px;
              padding: 15px 22px;
              font: inherit;
              font-weight: 600;
              background: #1f6feb;
              color: #fff;
              cursor: pointer;
              box-shadow: 0 12px 24px rgba(31, 111, 235, 0.22);
            }
            .status {
              min-height: 22px;
              margin-top: 10px;
              color: #0f5132;
              font-size: 14px;
            }
            .content {
              margin-top: 18px;
              font-size: 14px;
              color: var(--muted);
              line-height: 1.7;
              word-break: break-word;
            }
          </style>
        </head>
        <body>
          <main class="card">
            <p class="eyebrow">LAN Text Share</p>
            <h1>来自 iPhone 的文本</h1>
            <textarea id="text">\(escapedText)</textarea>
            <button id="syncButton" type="button">同步到手机</button>
            <div class="status" id="status"></div>
            <div class="content">在这个页面修改文本后，点击“同步到手机”，手机 App 内的文本内容会立即更新。</div>
          </main>
          <script>
            const button = document.getElementById('syncButton');
            const textArea = document.getElementById('text');
            const status = document.getElementById('status');

            button.addEventListener('click', async () => {
              button.disabled = true;
              status.textContent = '正在同步...';
              status.style.color = '#786b5d';

              try {
                const response = await fetch('/sync', {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'text/plain;charset=utf-8'
                  },
                  body: textArea.value
                });

                if (!response.ok) {
                  let message = '同步失败';
                  try {
                    const payload = await response.json();
                    if (payload && payload.error) {
                      message = payload.error;
                    }
                  } catch (_) {
                    message = response.status === 413
                      ? '文本过长，无法同步到手机。'
                      : '手机返回了错误（HTTP ' + response.status + '）';
                  }
                  throw new Error(message);
                }

                status.textContent = '已同步到手机';
                status.style.color = '#0f5132';
              } catch (error) {
                const rawMessage = error && error.message ? error.message : '';
                const message = rawMessage.includes('Failed to fetch')
                  ? '无法连接到手机，请确认手机分享弹窗仍然打开，且电脑和手机在同一 Wi-Fi 下。'
                  : rawMessage;
                status.textContent = '同步失败：' + message;
                status.style.color = '#b42318';
              } finally {
                button.disabled = false;
              }
            });
          </script>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func parseCompleteRequest(from data: Data) -> (requestLine: String, path: String, body: String)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        let bodyStartIndex = headerRange.upperBound
        let headerText = String(data: headerData, encoding: .utf8) ?? ""
        let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let contentLength = extractContentLength(from: headerText) ?? 0

        guard data.count >= bodyStartIndex + contentLength else {
            return nil
        }

        let bodyData = data.subdata(in: bodyStartIndex..<(bodyStartIndex + contentLength))
        let path = extractRequestPath(from: requestLine)
        let body = String(data: bodyData, encoding: .utf8) ?? ""
        return (requestLine: requestLine, path: path, body: body)
    }

    private static func extractContentLength(from headers: String) -> Int? {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }

    private static func extractRequestPath(from requestLine: String) -> String {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return ""
        }
        let rawPath = String(parts[1])
        return rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
    }

    private static func localIPv4Address() -> String? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let firstAddress = addressList else {
            return nil
        }

        defer {
            freeifaddrs(addressList)
        }

        var fallback: String?
        var pointer = firstAddress

        while true {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp, isRunning, !isLoopback, let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )

                if result == 0 {
                    let ip = String(cString: hostBuffer)
                    if name == "en0" {
                        return ip
                    }
                    if fallback == nil, isPrivateIPv4(ip) {
                        fallback = ip
                    }
                }
            }

            guard let next = interface.ifa_next else {
                break
            }
            pointer = next
        }

        return fallback
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }

        if parts[0] == 10 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        return false
    }
}

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var modifiedAt = Date()

    var title: String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新备忘录" : firstLine
    }

    var preview: String {
        let compact = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? "无附加文本" : compact
    }
}

final class AppViewModel: ObservableObject {
    @Published private(set) var notes: [Note]
    @Published private(set) var selectedNoteID: UUID
    @Published var text: String {
        didSet {
            updateSelectedNote()
            server.updateSharedText(text)
        }
    }
    @Published var showingShareSheet = false
    @Published var showingList = true

    let server: LocalTextShareServer
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let restoredNotes: [Note]
        if let data = UserDefaults.standard.data(forKey: AppDefaults.notesKey),
           let decoded = try? JSONDecoder().decode([Note].self, from: data), !decoded.isEmpty {
            restoredNotes = decoded
        } else {
            restoredNotes = [Note(text: UserDefaults.standard.string(forKey: AppDefaults.savedTextKey) ?? AppDefaults.initialText)]
        }
        self.notes = restoredNotes
        self.selectedNoteID = restoredNotes[0].id
        self.text = restoredNotes[0].text
        self.server = LocalTextShareServer(initialText: restoredNotes[0].text)

        server.$syncedText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                guard let self = self, self.text != newValue else { return }
                self.text = newValue
            }
            .store(in: &cancellables)

        server.$isSharingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                guard let self = self else { return }
                if !isEnabled && self.server.errorMessage == nil {
                    self.showingShareSheet = false
                }
            }
            .store(in: &cancellables)
    }

    func startSharing() {
        server.startSharing(text: text)
        showingShareSheet = true
    }

    func stopSharing() {
        server.stopSharing()
        showingShareSheet = false
    }

    func persistText() {
        updateSelectedNote()
    }

    func select(_ note: Note) {
        selectedNoteID = note.id
        text = note.text
        showingList = false
    }

    func createNote() {
        let note = Note(text: "")
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        text = ""
        persistNotes()
        showingList = false
    }

    func deleteSelectedNote() {
        guard let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        notes.remove(at: index)
        if notes.isEmpty { notes = [Note(text: "")] }
        let nextIndex = min(index, notes.count - 1)
        selectedNoteID = notes[nextIndex].id
        text = notes[nextIndex].text
        persistNotes()
    }

    func moveSelection(by offset: Int) {
        guard let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        let next = index + offset
        guard notes.indices.contains(next) else { return }
        select(notes[next])
    }

    var canMovePrevious: Bool { (notes.firstIndex { $0.id == selectedNoteID } ?? 0) > 0 }
    var canMoveNext: Bool { (notes.firstIndex { $0.id == selectedNoteID } ?? notes.count - 1) < notes.count - 1 }
    var currentNote: Note { notes.first(where: { $0.id == selectedNoteID }) ?? notes[0] }

    private func updateSelectedNote() {
        guard let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        notes[index].text = text
        notes[index].modifiedAt = Date()
        persistNotes()
    }

    private func persistNotes() {
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: AppDefaults.notesKey)
        }
    }
}

struct ShareAddressSheet: View {
    @ObservedObject var server: LocalTextShareServer
    let onClose: () -> Void
    @State private var showingCopiedToast = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                RetroTitleBar(title: "共享地址") {
                    Button(action: onClose) {
                        Text("关闭")
                            .frame(width: 50, height: 30)
                    }
                    .buttonStyle(GlossyCapsuleButtonStyle(
                        baseColor: Color(red: 0.12, green: 0.34, blue: 0.67),
                        fontSize: 14
                    ))
                }

                ZStack {
                    Color.retroWoodDark
                    LinearGradient(
                        colors: [Color.retroWoodLight, Color.retroWoodDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(0.7)

                    RuledPaperBackground()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.black.opacity(0.62), lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 2)
                        .padding(12)

                VStack(alignment: .leading, spacing: 18) {
                    if let shareURL = server.shareURL {
                        Text("请让电脑和手机连接同一个 Wi-Fi，然后在浏览器打开下面这个地址：")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(Color.retroWoodDark)

                        Text(shareURL.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.42))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.retroLeatherDark.opacity(0.55), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                        Button(action: copyAddress) {
                            HStack {
                                Image(systemName: "doc.on.doc")
                                Text("复制这个地址")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                        }
                        .buttonStyle(GlossyCapsuleButtonStyle(baseColor: Color(red: 0.12, green: 0.34, blue: 0.67)))

                        Text("电脑打开后会看到当前这段文本内容。")
                            .font(.footnote)
                            .foregroundColor(Color.retroLeatherDark)
                    } else if let errorMessage = server.errorMessage {
                        Text("分享启动失败")
                            .font(.headline)

                        Text(errorMessage)
                            .foregroundColor(Color(red: 0.62, green: 0.17, blue: 0.12))
                    } else {
                        HStack(spacing: 10) {
                            ActivityIndicator()
                            Text("正在启动局域网分享服务...")
                                .foregroundColor(Color.retroLeatherDark)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(32)
                }

                if showingCopiedToast {
                    Text("已复制")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.82))
                        .clipShape(Capsule())
                        .padding(.top, 12)
                }
            }
        }
        .edgesIgnoringSafeArea(.bottom)
    }

    private func copyAddress() {
        guard let shareURL = server.shareURL else { return }
        UIPasteboard.general.string = shareURL.absoluteString
        withAnimation(.easeInOut(duration: 0.2)) {
            showingCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showingCopiedToast = false
            }
        }
    }
}

struct NotesListView: View {
    @ObservedObject var viewModel: AppViewModel
    private let dateFormatter: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "M/d/yy"; return f }()

    var body: some View {
        VStack(spacing: 0) {
            RetroTitleBar(title: "Notes (\(viewModel.notes.count))") {
                Button(action: viewModel.createNote) {
                    OldOSHeaderControl(title: nil, iconName: "oldos-toolbar-plus")
                        .frame(width: 44, height: 30)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .frame(maxWidth: .infinity)

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color.retroPaper
                    if let paper = oldOSImage(named: "oldos-notes-body") {
                        paper
                            .resizable()
                            .scaledToFill()
                            .clipped()
                    }
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 1) {
                            ForEach(viewModel.notes) { note in
                                Button(action: { viewModel.select(note) }) {
                                    HStack(spacing: 12) {
                                        Text(note.title)
                                            .font(.custom("MarkerFelt-Thin", size: 16))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                        Text(dateFormatter.string(from: note.modifiedAt))
                                            .font(.system(size: 17))
                                            .foregroundColor(.gray)
                                            .fixedSize()
                                            .layoutPriority(1)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(Color.retroLeatherDark.opacity(0.7))
                                            .layoutPriority(1)
                                    }
                                    .foregroundColor(Color.retroLeatherDark)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 18)
                                    .frame(width: geometry.size.width, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .overlay(Rectangle().fill(Color.retroPaperLine.opacity(0.6)).frame(height: 1), alignment: .bottom)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .frame(width: geometry.size.width, alignment: .leading)
                    }
                    .frame(width: geometry.size.width, alignment: .leading)
                }
                .clipped()
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showingDeleteConfirmation = false
    @State private var editorScrollOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            if viewModel.showingList { NotesListView(viewModel: viewModel) } else { editor }
            if viewModel.showingShareSheet { ShareAddressSheet(server: viewModel.server) { viewModel.showingShareSheet = false } }
        }
        .onAppear { viewModel.server.updateSharedText(viewModel.text) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in viewModel.persistText() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in viewModel.persistText() }
        .edgesIgnoringSafeArea(.bottom)
        .actionSheet(isPresented: $showingDeleteConfirmation) {
            ActionSheet(title: Text("Delete Note?"), buttons: [
                .destructive(Text("Delete Note"), action: viewModel.deleteSelectedNote),
                .cancel(Text("Cancel"))
            ])
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            RetroTitleBar(
                title: viewModel.currentNote.title,
                truncatesTitle: true,
                leading: AnyView(
                    Button(action: { viewModel.showingList = true }) {
                        OldOSHeaderControl(title: "Notes", iconName: nil)
                            .frame(width: 62, height: 30)
                    }
                    .buttonStyle(PlainButtonStyle())
                )
            ) {
                Button(action: viewModel.createNote) {
                    OldOSHeaderControl(title: nil, iconName: "oldos-toolbar-plus")
                        .frame(width: 44, height: 30)
                }
                .buttonStyle(PlainButtonStyle())
            }
            ZStack(alignment: .bottom) {
                RuledPaperBackground(lineOffset: editorScrollOffset)
                StableTextEditor(
                    text: Binding(get: { viewModel.text }, set: { viewModel.text = $0 }),
                    scrollOffset: $editorScrollOffset
                )
                    .padding(.leading, 40)
                    .padding(.top, 42)
                    .padding(.bottom, 92)

                HStack {
                    Text("Today")
                    Spacer()
                    Text(editorDate)
                }
                    .font(.custom("MarkerFelt-Wide", size: 16))
                    .foregroundColor(Color.retroMetadata.opacity(0.86))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 40)
                    .padding(.trailing, 34)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    .offset(y: -editorScrollOffset)

                HStack(spacing: 0) {
                    toolButton("oldos-previous", enabled: viewModel.canMovePrevious) { viewModel.moveSelection(by: -1) }
                    toolButton(viewModel.server.isSharingEnabled ? "wifi.slash" : "wifi", enabled: true) { viewModel.server.isSharingEnabled ? viewModel.stopSharing() : viewModel.startSharing() }
                    toolButton("oldos-trash", enabled: true) { showingDeleteConfirmation = true }
                    toolButton("oldos-next", enabled: viewModel.canMoveNext) { viewModel.moveSelection(by: 1) }
                }
                .padding(.horizontal, 5)
                .padding(.bottom, 26)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func toolButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if icon == "oldos-trash" {
                if let trash = oldOSImage(named: "oldos-notes-trash") {
                    trash.renderingMode(.original).resizable().scaledToFit().frame(width: 30, height: 36)
                }
            } else if icon == "oldos-previous" {
                if let previous = oldOSImage(named: "oldos-notes-previous") {
                    previous.renderingMode(.original).resizable().scaledToFit().frame(width: 34, height: 34)
                }
            } else if icon == "oldos-next" {
                if let next = oldOSImage(named: "oldos-notes-next") {
                    next.renderingMode(.original).resizable().scaledToFit().frame(width: 34, height: 34)
                }
            } else if icon == "wifi" || icon == "wifi.slash" {
                Image(systemName: icon).font(.system(size: 23, weight: .regular))
            } else {
                Image(systemName: icon).font(.system(size: 23, weight: .regular))
            }
        }
        .frame(width: 52, height: 44)
        .foregroundColor(Color.retroLeatherLight)
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
        .grayscale(enabled ? 0 : 1)
        .opacity(enabled ? 1 : 0.5)
    }

    private var editorDate: String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMM d  HH:mm"; return f.string(from: viewModel.currentNote.modifiedAt) }
}

/// Keeps the note surface continuous at the screen edges, without system white bars.
final class ImmersiveHostingController<Content: View>: UIHostingController<Content> {
    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { false }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let viewModel = AppViewModel()

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
#if DEBUG
        // Used only by the simulator smoke-test workflow to capture each
        // screen without relying on fragile coordinate taps.
        if CommandLine.arguments.contains("-HelloIPA.ShowDetail") {
            viewModel.showingList = false
        }
        if CommandLine.arguments.contains("-HelloIPA.ShowShare") {
            viewModel.showingShareSheet = true
        }
#endif
        window.rootViewController = ImmersiveHostingController(rootView: ContentView(viewModel: viewModel))
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        viewModel.persistText()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        viewModel.persistText()
    }
}

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
