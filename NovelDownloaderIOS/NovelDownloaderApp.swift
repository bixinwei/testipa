import SwiftUI
import WebKit
import UIKit

@main
struct NovelDownloaderApp: App {
    @StateObject private var model = DownloadModel()

    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}

struct Chapter: Codable, Identifiable, Hashable {
    let title: String
    let url: String
    var id: String { url }
}

struct PageSnapshot: Codable {
    let url: String
    let links: [Chapter]
}

struct Analysis: Codable {
    let title: String
    let contentSelector: String
    let chapterURLContains: String
    let directoryPageCount: Int
}

enum DownloadError: LocalizedError {
    case verificationRequired
    case invalidResponse(String)
    case noChapters

    var errorDescription: String? {
        switch self {
        case .verificationRequired: return "网站要求完成 Cloudflare 或年龄确认。请先打开验证浏览器并手动完成验证。"
        case .invalidResponse(let message): return message
        case .noChapters: return "未能从目录页识别章节。"
        }
    }
}

@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var currentURL = ""
    @Published var isLoading = false
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func openForVerification(_ value: String) {
        guard let url = URL(string: value) else { return }
        webView.load(URLRequest(url: url))
    }

    func fetchHTML(_ value: String) async throws -> String {
        guard let url = URL(string: value) else { throw DownloadError.invalidResponse("目录地址无效。") }
        isLoading = true
        defer { isLoading = false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            self.webView.load(URLRequest(url: url))
        }
        try await Task.sleep(for: .milliseconds(900))
        let html = try await evaluate("document.documentElement.outerHTML") as? String ?? ""
        let lower = html.lowercased()
        if lower.contains("cf-turnstile") || lower.contains("verify you are human") || html.contains("正在进行安全验证") || html.contains("年龄确认") {
            throw DownloadError.verificationRequired
        }
        return html
    }

    func links(_ html: String, baseURL: String) async throws -> [Chapter] {
        // Extract only link text and URL from the already-loaded DOM. No novel
        // body is sent to the AI or retained in metadata.
        let script = """
        JSON.stringify(Array.from(document.querySelectorAll('a[href]')).map(a => ({
          title: (a.innerText || a.textContent || '').trim(), url: a.href
        })).filter(x => x.title && x.url))
        """
        guard let raw = try await evaluate(script) as? String,
              let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Chapter].self, from: data)) ?? []
    }

    func text(using selector: String) async throws -> String {
        let selectorJSON = try JSONEncoder().encode(selector)
        let quoted = String(data: selectorJSON, encoding: .utf8) ?? "''"
        let script = """
        (() => { const n = document.querySelector(\(quoted)); return n ? n.innerText : ''; })()
        """
        return try await evaluate(script) as? String ?? ""
    }

    func pageURL() -> String { webView.url?.absoluteString ?? "" }

    private func evaluate(_ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as Any) }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        currentURL = webView.url?.absoluteString ?? currentURL
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url?.absoluteString ?? currentURL
        continuation?.resume(returning: ())
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

struct BrowserView: UIViewRepresentable {
    @ObservedObject var browser: BrowserSession
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct DeepSeekClient {
    let apiKey: String
    let baseURL: String
    let model: String

    func analyze(indexURL: String, pages: [PageSnapshot]) async throws -> Analysis {
        let compactPages = pages.map { page in
            ["url": page.url, "links": page.links.map { ["title": $0.title, "url": $0.url] }]
        }
        let prompt = """
        你是小说下载器的导航分析器。只分析目录链接，绝不输出或要求正文。
        已由应用沿真实“下一页”导航收集到以下目录页链接（JSON）：
        \(String(data: try JSONSerialization.data(withJSONObject: compactPages), encoding: .utf8) ?? "[]")
        返回且只返回 JSON，字段必须为：title、contentSelector、chapterURLContains、directoryPageCount。
        directoryPageCount 必须是上面实际目录页数量；chapterURLContains 必须仅匹配正文链接。
        contentSelector 对 8xsk 通常是 #content；若目录数据未包含正文结构，使用最合理的正文容器选择器。
        """
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.1,
            "response_format": ["type": "json_object"],
            "messages": [["role": "user", "content": prompt]]
        ]
        guard let endpoint = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw DownloadError.invalidResponse("DeepSeek 地址无效。")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.invalidResponse("DeepSeek 分析请求失败。")
        }
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = envelope?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = (message?["content"] as? String) ?? ""
        guard let output = content.data(using: .utf8) else { throw DownloadError.invalidResponse("AI 没有返回分析结果。") }
        return try JSONDecoder().decode(Analysis.self, from: output)
    }
}

@MainActor
final class DownloadModel: ObservableObject {
    @Published var url = ""
    @Published var apiKey = ""
    @Published var baseURL = "https://api.deepseek.com/v1"
    @Published var model = "deepseek-chat"
    @Published var availableModels: [String] = []
    @Published var status = "先打开验证浏览器，完成网站验证后再开始下载。"
    @Published var logs: [String] = []
    @Published var progress = 0.0
    @Published var isDownloading = false
    @Published var isPaused = false
    @Published var showingBrowser = false
    @Published var exportedFile: URL?
    let browser = BrowserSession()

    init() {
        url = UserDefaults.standard.string(forKey: "novel.url") ?? ""
        apiKey = UserDefaults.standard.string(forKey: "novel.apiKey") ?? ""
        baseURL = UserDefaults.standard.string(forKey: "novel.baseURL") ?? baseURL
        model = UserDefaults.standard.string(forKey: "novel.model") ?? model
    }

    func saveSettings() {
        UserDefaults.standard.set(url, forKey: "novel.url")
        UserDefaults.standard.set(apiKey, forKey: "novel.apiKey")
        UserDefaults.standard.set(baseURL, forKey: "novel.baseURL")
        UserDefaults.standard.set(model, forKey: "novel.model")
    }

    func saveConfiguration() {
        saveSettings()
        report("[程序] 配置已保存到本机。")
    }

    func refreshModels() {
        guard !apiKey.isEmpty else { report("[程序] 请先填写 API Key，再刷新模型列表。"); return }
        Task {
            do {
                report("[程序] 正在刷新模型列表…")
                let root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let endpoint = URL(string: root + "/models") else {
                    throw DownloadError.invalidResponse("API 地址无效。")
                }
                var request = URLRequest(url: endpoint)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw DownloadError.invalidResponse("模型列表请求失败。")
                }
                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let entries = payload?["data"] as? [[String: Any]] ?? []
                let models = entries.compactMap { $0["id"] as? String }.sorted()
                guard !models.isEmpty else { throw DownloadError.invalidResponse("接口没有返回可用模型。") }
                availableModels = models
                if !models.contains(model) { model = models[0] }
                report("[程序] 已刷新 \(models.count) 个模型。")
            } catch {
                report("[程序] 刷新模型列表失败：\(error.localizedDescription)")
            }
        }
    }

    func togglePause() {
        guard isDownloading else { return }
        isPaused.toggle()
        report(isPaused ? "[阶段] 已请求暂停：当前章节完成后暂停。" : "[阶段] 已恢复下载。")
    }

    private func report(_ message: String) {
        status = message
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    func openBrowser() {
        saveSettings(); report("[程序] 已打开验证浏览器，请手动完成网站验证。")
        browser.openForVerification(url); showingBrowser = true
    }

    func download() {
        Task { await performDownload() }
    }

    private func performDownload() async {
        guard !apiKey.isEmpty else { report("[程序] 请先填写 DeepSeek API Key。"); return }
        saveSettings(); isDownloading = true; isPaused = false; progress = 0
        defer { isDownloading = false; isPaused = false }
        do {
            report("[程序] 正在读取目录与分页导航…")
            let pages = try await collectDirectoryPages()
            report("[AI] 正在确认目录页数与章节规则…")
            let analysis = try await DeepSeekClient(apiKey: apiKey, baseURL: baseURL, model: model).analyze(indexURL: url, pages: pages)
            guard analysis.directoryPageCount == pages.count else {
                throw DownloadError.invalidResponse("AI 返回的目录页数与实际导航不一致，已取消下载以避免漏章。")
            }
            let allLinks = pages.flatMap(\.links)
            var seen = Set<String>(); let chapters = allLinks.filter { link in
                link.url.contains(analysis.chapterURLContains) && seen.insert(link.url).inserted
            }
            guard !chapters.isEmpty else { throw DownloadError.noChapters }
            var output = ""
            for (index, chapter) in chapters.enumerated() {
                while isPaused {
                    try await Task.sleep(for: .milliseconds(250))
                }
                report("[程序] [\(index + 1)/\(chapters.count)] 下载《\(chapter.title)》…")
                _ = try await browser.fetchHTML(chapter.url)
                let text = try await browser.text(using: analysis.contentSelector)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                output += "\(chapter.title)\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
                progress = Double(index + 1) / Double(chapters.count)
            }
            let safe = analysis.title.replacingOccurrences(of: "/", with: "_")
            let outputURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("\(safe).txt")
            try output.write(to: outputURL, atomically: true, encoding: .utf8)
            exportedFile = outputURL
            report("[阶段] 下载完成：共 \(chapters.count) 章，可导出 TXT。")
        } catch {
            report("[程序] 下载失败：\(error.localizedDescription)")
        }
    }

    private func collectDirectoryPages() async throws -> [PageSnapshot] {
        var pages: [PageSnapshot] = []
        var visited = Set<String>()
        var current = url
        while !current.isEmpty && !visited.contains(current) && pages.count < 50 {
            _ = try await browser.fetchHTML(current)
            let actual = browser.pageURL()
            if visited.contains(actual) { break }
            let links = try await browser.links("", baseURL: actual)
            visited.insert(actual); pages.append(PageSnapshot(url: actual, links: links))
            // Follow the page's explicit Next navigation only — never invent a
            // higher page number. This handles sites that redirect invalid pages.
            let next = links.first { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).contains("下一页") }?.url
            guard let next, next != actual, !next.hasSuffix("#") else { break }
            current = next
        }
        return pages
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: DownloadModel
    @State private var showingShare = false

    var body: some View {
        NavigationStack {
            Form {
                Section("下载设置") {
                    TextField("小说目录页 URL", text: $model.url).textInputAutocapitalization(.never).keyboardType(.URL)
                    SecureField("DeepSeek API Key", text: $model.apiKey)
                    TextField("API 地址", text: $model.baseURL).textInputAutocapitalization(.never).keyboardType(.URL)
                    if model.availableModels.isEmpty {
                        TextField("模型", text: $model.model).textInputAutocapitalization(.never)
                    } else {
                        Picker("模型", selection: $model.model) {
                            ForEach(model.availableModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button("刷新模型列表") { model.refreshModels() }
                    Button("保存配置") { model.saveConfiguration() }
                }
                Section("网站验证") {
                    Button("打开验证浏览器") { model.openBrowser() }
                    Text("在内置浏览器手动完成 Cloudflare 或年龄确认。应用不会自动绕过验证。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("下载") {
                    HStack {
                        Button(model.isDownloading ? "正在下载…" : "开始下载") { model.download() }
                            .disabled(model.isDownloading || model.url.isEmpty || model.apiKey.isEmpty)
                        if model.isDownloading {
                            Spacer()
                            Button(model.isPaused ? "继续下载" : "暂停下载") { model.togglePause() }
                        }
                    }
                    if model.isDownloading { ProgressView(value: model.progress) }
                    Text(model.status).font(.footnote).textSelection(.enabled)
                    if let file = model.exportedFile {
                        Button("导出 TXT") { showingShare = true }
                            .sheet(isPresented: $showingShare) { ShareSheet(items: [file]) }
                    }
                }
                Section("运行日志") {
                    if model.logs.isEmpty {
                        Text("暂时没有日志。").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(model.logs.enumerated()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(minHeight: 130, maxHeight: 210)
                    }
                }
            }
            .navigationTitle("小说下载器")
            .sheet(isPresented: $model.showingBrowser) {
                NavigationStack { BrowserView(browser: model.browser).navigationTitle("网站验证").navigationBarTitleDisplayMode(.inline) }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
