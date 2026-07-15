import SwiftUI
import Network
import Foundation
import Darwin
import UIKit

enum AppDefaults {
    static let initialText = """
    这是一段示例文本。
    点击“分享文本”后，局域网内的电脑打开地址即可看到它。
    """
}

extension View {
    @ViewBuilder
    func textEditorBackgroundHiddenIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

final class LocalTextShareServer: ObservableObject {
    @Published private(set) var shareURL: URL?
    @Published private(set) var errorMessage: String?
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

        if listener != nil {
            return
        }

        nextPortIndex = 0
        tryNextPort()
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
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            var buffer = accumulatedData
            if let data, !data.isEmpty {
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
            .tip {
              margin-top: 14px;
              color: var(--muted);
              font-size: 14px;
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

struct ShareAddressSheet: View {
    @ObservedObject var server: LocalTextShareServer
    @Environment(\.dismiss) private var dismiss
    @State private var showingCopiedToast = false

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                if let shareURL = server.shareURL {
                    Text("请让电脑和手机连接同一个 Wi-Fi，然后在浏览器打开下面这个地址：")
                        .font(.body)

                    Text(shareURL.absoluteString)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    Button {
                        UIPasteboard.general.string = shareURL.absoluteString
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingCopiedToast = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingCopiedToast = false
                            }
                        }
                    } label: {
                        Label("复制这个地址", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("电脑打开后会看到当前这段文本内容。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let errorMessage = server.errorMessage {
                    Text("分享启动失败")
                        .font(.headline)

                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("正在启动局域网分享服务...")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .background(Color(red: 254 / 255, green: 254 / 255, blue: 254 / 255))
            .overlay(alignment: .top) {
                if showingCopiedToast {
                    Text("已复制")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.82))
                        .clipShape(Capsule())
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var server = LocalTextShareServer()
    @State private var text = AppDefaults.initialText
    @State private var showingShareSheet = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .textEditorBackgroundHiddenIfAvailable()
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color(red: 204 / 255, green: 1, blue: 153 / 255), lineWidth: 2)
                    )
                    .shadow(color: Color(red: 204 / 255, green: 1, blue: 153 / 255).opacity(0.9), radius: 12)
                    .shadow(color: Color(red: 204 / 255, green: 1, blue: 153 / 255).opacity(0.45), radius: 24)

                Button {
                    server.startSharing(text: text)
                    showingShareSheet = true
                } label: {
                    Label("分享文本", systemImage: "network")
                        .font(.headline)
                        .frame(width: 148, height: 52)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(Color(red: 254 / 255, green: 254 / 255, blue: 254 / 255))
            .navigationBarHidden(true)
        }
        .onAppear {
            UITextView.appearance().backgroundColor = .clear
            server.updateSharedText(text)
        }
        .onChange(of: text) { newValue in
            server.updateSharedText(newValue)
        }
        .onReceive(server.$syncedText) { newValue in
            if text != newValue {
                text = newValue
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareAddressSheet(server: server)
        }
    }
}

@main
struct HelloIPAApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
