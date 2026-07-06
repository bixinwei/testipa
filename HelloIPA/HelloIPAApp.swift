import SwiftUI
import WebKit

final class BrowserModel: ObservableObject {
    @Published var urlText: String = "https://example.com"
    @Published var currentURL: URL? = nil

    func openInSystem() {
        guard let url = normalizedURL(from: urlText) else { return }
        UIApplication.shared.open(url)
    }

    func openInWebView() {
        guard let url = normalizedURL(from: urlText) else { return }
        currentURL = url
    }

    private func normalizedURL(from raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }

        return URL(string: "https://\(raw)")
    }
}

struct EmbeddedWebView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> WKWebView {
        WKWebView(frame: .zero)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let url else { return }
        webView.load(URLRequest(url: url))
    }
}

struct ContentView: View {
    @StateObject private var model = BrowserModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("hello")
                .font(.system(size: 34, weight: .bold))

            TextField("Enter URL", text: $model.urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button("Open URL") {
                    model.openInSystem()
                }
                .buttonStyle(.borderedProminent)

                Button("Load WebView") {
                    model.openInWebView()
                }
                .buttonStyle(.bordered)
            }

            EmbeddedWebView(url: model.currentURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if model.currentURL == nil {
                        Text("WebView idle")
                            .foregroundColor(.secondary)
                    }
                }
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
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
