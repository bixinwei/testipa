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

final class LocalTextShareServer: ObservableObject {
    @Published private(set) var shareURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncedText: String

    private let queue = DispatchQueue(label: "helloipa.local-text-server")
    private let preferredPorts: [UInt16] = [8080, 8081, 8082, 8090]
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let requestLine = request.components(separatedBy: "\r\n").first ?? ""
            let path = Self.extractRequestPath(from: requestLine)
            let response: String

            if requestLine.hasPrefix("GET "), path == "/" {
                let body = self.makeHTMLPage(with: self.currentText)
                response = self.httpResponse(
                    statusLine: "HTTP/1.1 200 OK\r\n",
                    contentType: "text/html; charset=utf-8",
                    body: body
                )
            } else if requestLine.hasPrefix("POST "), path == "/sync" {
                let bodyText = Self.extractHTTPBody(from: request)
                self.updateSharedText(bodyText)
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
              border-radius: 14px;
              padding: 14px 18px;
              font: inherit;
              font-weight: 600;
              background: #1f6feb;
              color: #fff;
              cursor: pointer;
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

              try {
                const response = await fetch('/sync', {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'text/plain;charset=utf-8'
                  },
                  body: textArea.value
                });

                if (!response.ok) {
                  throw new Error('HTTP ' + response.status);
                }

                status.textContent = '已同步到手机';
              } catch (error) {
                status.textContent = '同步失败：' + error.message;
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

    private static func extractHTTPBody(from request: String) -> String {
        let separator = "\r\n\r\n"
        guard let range = request.range(of: separator) else {
            return ""
        }
        return String(request[range.upperBound...])
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
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

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
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    Button {
                        UIPasteboard.general.string = shareURL.absoluteString
                    } label: {
                        Label("复制这个地址", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                Divider()

                Text("当前文本预览")
                    .font(.headline)

                ScrollView {
                    Text(text.isEmpty ? "暂无文本" : text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                        )
                }
            }
            .padding(20)
            .navigationTitle("局域网分享")
            .navigationBarTitleDisplayMode(.inline)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("文本内容")
                            .font(.headline)

                        TextEditor(text: $text)
                            .frame(minHeight: 220)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("App 内预览")
                            .font(.headline)

                        Text(text.isEmpty ? "请输入要分享的文本" : text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.99, green: 0.97, blue: 0.93), Color.white],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22)
                                    .stroke(Color(red: 0.89, green: 0.84, blue: 0.77), lineWidth: 1)
                            )
                    }

                    Button {
                        server.startSharing(text: text)
                        showingShareSheet = true
                    } label: {
                        Label("分享文本", systemImage: "network")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("分享后会弹出一个 `http://` 地址。局域网电脑在浏览器打开这个地址，就能看到当前文本。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("局域网文本分享")
        }
        .onAppear {
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
            ShareAddressSheet(server: server, text: $text)
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
