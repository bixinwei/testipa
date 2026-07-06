import SwiftUI
import WebKit

final class BrowserModel: ObservableObject {
    @Published var urlText: String = "https://example.com"
    @Published var currentURL: URL? = URL(string: "https://example.com")
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var pageTitle = "HelloIPA Browser"
    @Published var blockAnimatedImages = false
    @Published var selectedImageURL: String?

    weak var webView: BrowserWebView?

    func attach(webView: BrowserWebView) {
        self.webView = webView
        syncState(from: webView)
        applyAnimatedImagePolicy()
    }

    func loadTypedURL() {
        guard let url = normalizedURL(from: urlText) else { return }
        currentURL = url
        webView?.load(URLRequest(url: url))
    }

    func openInSystem() {
        guard let url = normalizedURL(from: urlText) else { return }
        UIApplication.shared.open(url)
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        if webView?.url == nil, let url = normalizedURL(from: urlText) {
            currentURL = url
            webView?.load(URLRequest(url: url))
            return
        }
        webView?.reload()
    }

    func applyAnimatedImagePolicy() {
        webView?.setGIFBlockingEnabled(blockAnimatedImages)
    }

    func syncState(from webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title?.isEmpty == false ? webView.title! : "HelloIPA Browser"
        if let url = webView.url {
            currentURL = url
            urlText = url.absoluteString
        }
    }

    private func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        return URL(string: "https://\(trimmed)")
    }
}

final class BrowserWebView: WKWebView {
    static let imageMessageName = "helloipaImageURL"
    private static let imageScriptSource = """
    (function() {
      if (window.__helloipaImageHookInstalled) { return; }
      window.__helloipaImageHookInstalled = true;
      document.addEventListener('dblclick', function(event) {
        var node = event.target;
        while (node && node !== document) {
          if (node.tagName && node.tagName.toLowerCase() === 'img') {
            var src = node.currentSrc || node.src || '';
            if (src && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(imageMessageName)) {
              window.webkit.messageHandlers.\(imageMessageName).postMessage(src);
            }
            break;
          }
          node = node.parentNode;
        }
      }, true);
    })();
    """

    private var gifRuleList: WKContentRuleList?
    private var gifBlockingEnabled = false

    convenience init(coordinator: EmbeddedWebView.Coordinator) {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        configuration.userContentController.add(coordinator, name: Self.imageMessageName)
        let script = WKUserScript(source: Self.imageScriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        configuration.userContentController.addUserScript(script)
        self.init(frame: .zero, configuration: configuration)
    }

    func setGIFBlockingEnabled(_ enabled: Bool) {
        gifBlockingEnabled = enabled
        updateGIFBlockingRule()
    }

    private func updateGIFBlockingRule() {
        let controller = configuration.userContentController
        if #available(iOS 11.0, *) {
            controller.removeAllContentRuleLists()
        }

        guard gifBlockingEnabled else {
            gifRuleList = nil
            return
        }

        let rules = """
        [
          {
            "trigger": {
              "url-filter": ".*\\\\.gif([?#].*)?$",
              "resource-type": ["image"]
            },
            "action": {
              "type": "block"
            }
          }
        ]
        """

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "helloipa.block.gif",
            encodedContentRuleList: rules
        ) { [weak self] ruleList, _ in
            guard let self, let ruleList else { return }
            self.gifRuleList = ruleList
            self.configuration.userContentController.add(ruleList)
            self.reload()
        }
    }
}

struct EmbeddedWebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> BrowserWebView {
        let webView = BrowserWebView(coordinator: context.coordinator)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        model.attach(webView: webView)

        if let url = model.currentURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: BrowserWebView, context: Context) {
        model.attach(webView: webView)
        webView.setGIFBlockingEnabled(model.blockAnimatedImages)

        guard let targetURL = model.currentURL else { return }
        if webView.url?.absoluteString != targetURL.absoluteString {
            webView.load(URLRequest(url: targetURL))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let model: BrowserModel

        init(model: BrowserModel) {
            self.model = model
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.syncState(from: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.syncState(from: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            model.syncState(from: webView)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
                model.syncState(from: webView)
            }
            return nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == BrowserWebView.imageMessageName else { return }
            guard let url = message.body as? String, !url.isEmpty else { return }
            DispatchQueue.main.async {
                self.model.selectedImageURL = url
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = BrowserModel()

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.pageTitle)
                    .font(.headline)
                    .lineLimit(1)

                Text(model.currentURL?.absoluteString ?? "No page loaded")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                TextField("Enter URL", text: $model.urlText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                Button("Visit") {
                    model.loadTypedURL()
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                Button("Back") {
                    model.goBack()
                }
                .buttonStyle(.bordered)
                .disabled(!model.canGoBack)

                Button("Forward") {
                    model.goForward()
                }
                .buttonStyle(.bordered)
                .disabled(!model.canGoForward)

                Button("Reload") {
                    model.reload()
                }
                .buttonStyle(.bordered)

                Button("Open Outside") {
                    model.openInSystem()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("Block GIF", isOn: $model.blockAnimatedImages)
                .onChange(of: model.blockAnimatedImages) { _ in
                    model.applyAnimatedImagePolicy()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            EmbeddedWebView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .alert("Image URL", isPresented: Binding(
            get: { model.selectedImageURL != nil },
            set: { showing in
                if !showing {
                    model.selectedImageURL = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                model.selectedImageURL = nil
            }
        } message: {
            Text(model.selectedImageURL ?? "")
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
