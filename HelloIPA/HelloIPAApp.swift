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
private func oldOSUIImage(named name: String) -> UIImage? {
    guard let path = Bundle.main.path(forResource: name, ofType: "png"),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let image = UIImage(data: data, scale: 2) else { return nil }
    return image
}

private func oldOSImage(named name: String) -> Image? {
    guard let image = oldOSUIImage(named: name) else { return nil }
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

/// Match OldOS Notes.swift: the NotesBack asset is itself the complete
/// semi-transparent, 3-part horizontally stretchable return-button image.
struct OldOSHeaderControl: View {
    let title: String?
    let iconName: String?

    var body: some View {
        Group {
            if let title = title {
                ZStack {
                    if let background = oldOSImage(named: "oldos-notes-back") {
                        background
                            .resizable(
                                capInsets: EdgeInsets(top: 0, leading: 13, bottom: 0, trailing: 5.5),
                                resizingMode: .stretch
                            )
                    }

                    Text(title)
                        .font(.custom("Helvetica Neue Bold", size: 13))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: -0.6)
                        .lineLimit(1)
                        .padding(.leading, 5)
                        .offset(y: -1.1)
                }
            } else {
                ZStack {
                    if let buttonCenter = oldOSImage(named: "oldos-notes-button-center") {
                        buttonCenter
                            .resizable(
                                capInsets: EdgeInsets(top: 10, leading: 5, bottom: 10, trailing: 5),
                                resizingMode: .stretch
                            )
                    }

                    if let iconName = iconName, let icon = oldOSImage(named: iconName) {
                        icon
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 17)
                    }
                }
            }
        }
        .frame(height: title == nil ? 32 : 33)
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

            Text(displayTitle)
                .font(.custom("Helvetica Neue Bold", size: 22))
                .foregroundColor(.white)
                .shadow(color: Color.black.opacity(0.21), radius: 0, x: 0, y: -1)
                .lineLimit(1)

            if let leading = leading {
                leading
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 5)
            }

            trailing()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 5)
        }
        .frame(height: 60)
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

/// This is hosted inside the UITextView, matching OldOS's `destination_header`.
/// A scroll view moves its subviews with its content, so the metadata and the
/// ruled text share one coordinate system instead of being two SwiftUI overlays.
struct NoteMetadata: Equatable {
    let relativeDate: String
    let timestamp: String
}

struct NoteMetadataHeader: View {
    let metadata: NoteMetadata

    var body: some View {
        HStack {
            Text(metadata.relativeDate)
                .font(.custom("Helvetica Neue Bold", size: 14))
            Spacer()
            Text(metadata.timestamp)
                .font(.custom("Helvetica Neue Regular", size: 14))
        }
        .foregroundColor(Color(red: 161/255, green: 93/255, blue: 68/255))
        .padding(.leading, 32)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 15)
        .background(Color.clear)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Swift port of OldOS/TextView/DALinedTextView.m. Lines belong to the scrolling
/// UITextView, so they stay registered with the glyph baselines while editing.
final class OldOSLinedTextView: UITextView {
    private let horizontalLineColor = UIColor(red: 78/255, green: 90/255, blue: 130/255, alpha: 0.4)
    private let verticalLineColor = UIColor(red: 161/255, green: 93/255, blue: 68/255, alpha: 0.45)

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext(), let font = font else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        context.setLineWidth(3 / scale)
        context.setStrokeColor(horizontalLineColor.cgColor)
        context.beginPath()

        let baseOffset = font.descender + 40
        let factor = font.pointSize * 0.015
        let correctedOffset = contentOffset.y - (contentOffset.y / font.lineHeight) * factor
        let firstLine = max(1, Int(correctedOffset / font.lineHeight))
        let lastLine = Int(ceil((contentOffset.y + bounds.height) / font.lineHeight))
        for line in firstLine...max(firstLine, lastLine) {
            let y = round((baseOffset + (font.lineHeight + factor) * CGFloat(line)) * scale) / scale
            context.move(to: CGPoint(x: bounds.minX, y: y))
            context.addLine(to: CGPoint(x: bounds.maxX, y: y))
        }
        context.strokePath()

        // This is the verticalLineColor path from DALinedTextView.m. It is
        // expressed in the scroll view's content coordinates, so it stays
        // continuous from the first ruled line through every scroll position.
        context.beginPath()
        context.setStrokeColor(verticalLineColor.cgColor)
        let marginX = bounds.minX + textContainerInset.left - 3 / scale
        context.move(to: CGPoint(x: marginX, y: bounds.minY))
        context.addLine(to: CGPoint(x: marginX, y: bounds.minY + bounds.height))
        context.strokePath()
    }

    override var font: UIFont? { didSet { setNeedsDisplay() } }
    override var textContainerInset: UIEdgeInsets { didSet { setNeedsDisplay() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        // UIKit's text container is independent of the SwiftUI wrapper's
        // layout proposal. Keep it tied to the actual rendered width so long
        // text can wrap but can never widen the note surface.
        textContainer.widthTracksTextView = true
        let availableWidth = max(0, bounds.width - textContainerInset.left - textContainerInset.right)
        if textContainer.size.width != availableWidth {
            textContainer.size = CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        }
    }
}

struct StableTextEditor: UIViewRepresentable {
    @Binding var text: String
    let metadata: NoteMetadata

    private static let noteFont = UIFont(name: "Noteworthy-Bold", size: 19) ?? .systemFont(ofSize: 19, weight: .bold)
    private static let noteTextColor = UIColor.black

    private static func noteAttributes() -> [NSAttributedString.Key: Any] {
        return [
            .font: noteFont,
            .foregroundColor: noteTextColor
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
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> OldOSLinedTextView {
        let textView = OldOSLinedTextView()
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
        textView.alwaysBounceHorizontal = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainerInset = UIEdgeInsets(top: 40, left: 28, bottom: 30, right: 3)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.attributedText = Self.styledText(text)
        context.coordinator.installMetadataHeader(in: textView, metadata: metadata)
        return textView
    }

    func updateUIView(_ textView: OldOSLinedTextView, context: Context) {
        // Keep the paper visible when the device changes appearance while the
        // editor is on screen.
        textView.isOpaque = false
        textView.backgroundColor = .clear
        textView.overrideUserInterfaceStyle = .light
        context.coordinator.updateMetadata(metadata)
        guard textView.text != text else { return }

        let selectedRange = textView.selectedRange
        textView.attributedText = Self.styledText(text)
        textView.typingAttributes = Self.noteAttributes()
        let clampedLocation = min(selectedRange.location, (textView.text as NSString).length)
        textView.selectedRange = NSRange(location: clampedLocation, length: 0)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        private var metadataController: UIHostingController<NoteMetadataHeader>?

        init(text: Binding<String>) {
            _text = text
        }

        func installMetadataHeader(in textView: OldOSLinedTextView, metadata: NoteMetadata) {
            let controller = UIHostingController(rootView: NoteMetadataHeader(metadata: metadata))
            let header = controller.view!
            header.translatesAutoresizingMaskIntoConstraints = false
            header.backgroundColor = .clear
            textView.addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: textView.topAnchor),
                header.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                header.widthAnchor.constraint(equalTo: textView.widthAnchor)
            ])
            metadataController = controller
        }

        func updateMetadata(_ metadata: NoteMetadata) {
            metadataController?.rootView = NoteMetadataHeader(metadata: metadata)
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
            // DALinedTextView draws the rules in the scroll view's content
            // coordinate space. Ask UIKit to redraw whenever that coordinate
            // space moves, exactly as its original implementation requires.
            (scrollView as? OldOSLinedTextView)?.setNeedsDisplay()
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
    @Published private(set) var syncedDocument: SharedNoteDocument

    private let queue = DispatchQueue(label: "helloipa.local-text-server")
    private let preferredPorts: [UInt16] = [8080, 8081, 8082, 8090]
    private let maxRequestSize = 1_048_576
    private var listener: NWListener?
    private var currentText: String
    private var currentImages: [NoteImage]
    private var currentPort: UInt16?
    private var nextPortIndex = 0

    init(initialText: String = AppDefaults.initialText, initialImages: [NoteImage] = []) {
        self.syncedDocument = SharedNoteDocument(text: initialText, images: initialImages)
        self.currentText = initialText
        self.currentImages = initialImages
    }

    func updateSharedText(_ text: String) {
        updateSharedDocument(text: text, images: currentImages)
    }

    func updateSharedDocument(text: String, images: [NoteImage]) {
        let document = SharedNoteDocument(text: text, images: images)
        queue.async {
            self.currentText = text
            self.currentImages = images
        }
        DispatchQueue.main.async {
            if self.syncedDocument != document {
                self.syncedDocument = document
            }
        }
    }

    func startSharing(text: String, images: [NoteImage]) {
        updateSharedDocument(text: text, images: images)
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
                let response: Data

                if request.requestLine.hasPrefix("GET "), request.path == "/" {
                    let body = self.makeHTMLPage(with: self.currentText, images: self.currentImages)
                    response = self.httpDataResponse(
                        statusLine: "HTTP/1.1 200 OK\r\n",
                        contentType: "text/html; charset=utf-8",
                        body: Data(body.utf8)
                    )
                } else if request.requestLine.hasPrefix("GET "),
                          request.path == "/paper",
                          let paperData = UIImage(named: "bodyMarginThin-568h")?.pngData() {
                    response = self.httpDataResponse(
                        statusLine: "HTTP/1.1 200 OK\r\n",
                        contentType: "image/png",
                        body: paperData,
                        additionalHeaders: ["Cache-Control": "private, max-age=3600"]
                    )
                } else if request.requestLine.hasPrefix("GET "),
                          let imageID = Self.previewImageID(from: request.path),
                          self.currentImages.contains(where: { $0.id == imageID }),
                          let previewData = NoteImageStore.shared.previewData(for: imageID) {
                    response = self.httpDataResponse(
                        statusLine: "HTTP/1.1 200 OK\r\n",
                        contentType: "image/jpeg",
                        body: previewData,
                        additionalHeaders: ["Cache-Control": "private, max-age=3600"]
                    )
                } else if request.requestLine.hasPrefix("GET "),
                          let imageID = Self.imageID(from: request.path),
                          let image = self.currentImages.first(where: { $0.id == imageID }),
                          let imageData = NoteImageStore.shared.originalData(for: image.id) {
                    response = self.httpDataResponse(
                        statusLine: "HTTP/1.1 200 OK\r\n",
                        contentType: image.mimeType,
                        body: imageData,
                        additionalHeaders: ["Cache-Control": "private, max-age=3600"]
                    )
                } else if request.requestLine.hasPrefix("POST "), request.path == "/sync" {
                    if let errorMessage = self.applyWebSync(request.body) {
                        let body = "{\"ok\":false,\"error\":\"\(errorMessage)\"}"
                        response = self.httpDataResponse(
                            statusLine: "HTTP/1.1 422 Unprocessable Content\r\n",
                            contentType: "application/json; charset=utf-8",
                            body: Data(body.utf8)
                        )
                    } else {
                        let body = "{\"ok\":true}"
                        response = self.httpDataResponse(
                            statusLine: "HTTP/1.1 200 OK\r\n",
                            contentType: "application/json; charset=utf-8",
                            body: Data(body.utf8)
                        )
                    }
                } else {
                    let body = "<html><body><h1>404</h1></body></html>"
                    response = self.httpDataResponse(
                        statusLine: "HTTP/1.1 404 Not Found\r\n",
                        contentType: "text/html; charset=utf-8",
                        body: Data(body.utf8)
                    )
                }

                connection.send(content: response, completion: .contentProcessed { _ in
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

    private func httpDataResponse(
        statusLine: String,
        contentType: String,
        body: Data,
        additionalHeaders: [String: String] = [:]
    ) -> Data {
        var header = statusLine
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
        for (name, value) in additionalHeaders {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private func makeHTMLPage(with text: String, images: [NoteImage]) -> String {
        let renderedDocument = Self.renderDocumentHTML(text: text, images: images)

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>HelloIPA 备忘录分享</title>
          <style>
            :root {
              color-scheme: light;
              --bg: #ffffff;
              --card: #ffffff;
              --text: #1f1a14;
              --muted: #786b5d;
              --line: #e5d7c5;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              min-height: 100vh;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background: var(--bg);
              color: var(--text);
              display: block;
              justify-content: center;
              padding: 24px;
            }
            .card {
              width: min(760px, 100%);
              background: var(--card);
              border: 0;
              border-radius: 0;
              padding: 28px;
              box-shadow: none;
              margin: 0 auto;
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
            .document-editor {
              width: 100%;
              min-height: 260px;
              /* The source paper's ruled margin occupies 48 px of its 640 px
                 bitmap.  Add the same proportional margin before the 28 px
                 Notes text inset, so web text begins to the right of both rules. */
              padding: 40px 28px 30px calc(7.5% + 28px);
              border-radius: 0;
              border: 0;
              background-color: #fff8c4;
              background-image: url('/paper');
              background-repeat: repeat-y;
              background-size: 100% auto;
              background-position: left top;
              color: var(--text);
              font-family: "Noteworthy", "Marker Felt", "Comic Sans MS", cursive;
              font-size: 19px;
              font-weight: 700;
              line-height: 1.6;
              white-space: pre-wrap;
              overflow-wrap: anywhere;
              outline: none;
            }
            .document-editor:focus {
              box-shadow: inset 0 0 0 1px rgba(121, 92, 62, 0.28);
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
            .image-block {
              margin: 14px 0;
              display: block;
              width: 80%;
              max-width: 80%;
              white-space: normal;
              vertical-align: top;
            }
            .image-block img {
              display: block;
              width: auto;
              max-width: 100%;
              height: auto;
              border-radius: 0;
              border: 0;
            }
          </style>
        </head>
        <body>
          <main class="card">
            <p class="eyebrow">LAN Notes Share</p>
            <h1>来自 iPhone 的备忘录</h1>
            <div
              id="editor"
              class="document-editor"
              contenteditable="true"
              role="textbox"
              aria-multiline="true"
            >\(renderedDocument)</div>
            <button id="syncButton" type="button">同步到手机</button>
            <div class="status" id="status"></div>
            <div class="content">直接在上方正文中编辑，完成后点击“同步到手机”。长按图片可使用浏览器的原生复制或保存操作。</div>
          </main>
          <script>
            const button = document.getElementById('syncButton');
            const editor = document.getElementById('editor');
            const status = document.getElementById('status');

            function serializeEditor() {
              const markers = new Map();
              let markerIndex = 0;
              let linearText = '';

              function append(value) {
                linearText += value;
              }

              function appendBlockBreak() {
                if (linearText.length > 0 && !linearText.endsWith('\\n')) {
                  append('\\n');
                }
              }

              function walk(node) {
                if (node.nodeType === Node.TEXT_NODE) {
                  append(node.nodeValue || '');
                  return;
                }
                if (node.nodeType !== Node.ELEMENT_NODE) {
                  return;
                }

                const element = node;
                if (element.tagName === 'BR') {
                  append('\\n');
                  return;
                }
                if (element.classList.contains('image-block') && element.dataset.imageId) {
                  appendBlockBreak();
                  const marker = `\\uE000HELLOIPA_IMAGE_${markerIndex}_\\uE001`;
                  markerIndex += 1;
                  markers.set(marker, element.dataset.imageId);
                  append(marker + '\\n');
                  return;
                }

                const isTextBlock = ['DIV', 'P', 'LI'].includes(element.tagName);
                if (isTextBlock) {
                  appendBlockBreak();
                }
                element.childNodes.forEach(walk);
                if (isTextBlock) {
                  appendBlockBreak();
                }
              }

              editor.childNodes.forEach(walk);
              linearText = linearText.replace(/\\r\\n?/g, '\\n');
              const markerPattern = /\\uE000HELLOIPA_IMAGE_(\\d+)_\\uE001/g;
              const images = [];
              let text = '';
              let cursor = 0;
              let match;

              while ((match = markerPattern.exec(linearText)) !== null) {
                text += linearText.slice(cursor, match.index);
                const marker = match[0];
                const id = markers.get(marker);
                if (id) {
                  images.push({ id, location: text.length });
                }
                cursor = match.index + marker.length;
              }
              text += linearText.slice(cursor);
              return { text, images };
            }

            button.addEventListener('click', async () => {
              button.disabled = true;
              status.textContent = '正在同步...';
              status.style.color = '#786b5d';

              try {
                const response = await fetch('/sync', {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'application/json;charset=utf-8'
                  },
                  body: JSON.stringify(serializeEditor())
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

    private static func renderDocumentHTML(text: String, images: [NoteImage]) -> String {
        let nsText = text as NSString
        let orderedImages = images.enumerated().sorted {
            if $0.element.location == $1.element.location {
                return $0.offset < $1.offset
            }
            return $0.element.location < $1.element.location
        }

        var html = ""
        var cursor = 0

        for (_, image) in orderedImages {
            let location = min(max(image.location, cursor), nsText.length)
            if location > cursor {
                html += escapeHTML(nsText.substring(with: NSRange(location: cursor, length: location - cursor)))
            }

            let previewPath = "/preview/\(image.id.uuidString)"
            let filename = escapeHTML(image.filename)
            html += """
            <div
              class="image-block"
              data-image-id="\(image.id.uuidString)"
              contenteditable="false"
            >
              <img src="\(previewPath)" alt="\(filename)">
            </div>
            """
            cursor = location
        }

        if cursor < nsText.length {
            html += escapeHTML(nsText.substring(from: cursor))
        }
        return html
    }

    /// Returns an error instead of applying an empty or malformed web payload.
    /// A failed browser serialization must never erase the selected note.
    private func applyWebSync(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(WebSyncPayload.self, from: data) else {
            return "网页同步数据无效，已保留手机上的备忘录。"
        }

        let maximumLocation = (payload.text as NSString).length
        let imagesByID = Dictionary(uniqueKeysWithValues: currentImages.map { ($0.id, $0) })
        var seenIDs = Set<UUID>()
        let updatedImages = payload.images.compactMap { position -> NoteImage? in
            guard seenIDs.insert(position.id).inserted,
                  var image = imagesByID[position.id] else {
                return nil
            }
            image.location = min(max(0, position.location), maximumLocation)
            return image
        }

        let currentImageIDs = Set(currentImages.map { $0.id })
        let receivedImageIDs = Set(updatedImages.map { $0.id })
        guard currentImageIDs == receivedImageIDs else {
            return "网页图片数据不完整，已取消同步以保护手机上的备忘录。"
        }

        let hasText = !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !updatedImages.isEmpty || (currentText.isEmpty && currentImages.isEmpty) else {
            return "网页正文为空，已取消同步以保护手机上的备忘录。"
        }
        updateSharedDocument(text: payload.text, images: updatedImages)
        return nil
    }

    private struct WebSyncPayload: Decodable {
        let text: String
        let images: [WebSyncImagePosition]
    }

    private struct WebSyncImagePosition: Decodable {
        let id: UUID
        let location: Int
    }

    private static func imageID(from path: String) -> UUID? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2, components[0] == "image" else { return nil }
        return UUID(uuidString: String(components[1]))
    }

    private static func previewImageID(from path: String) -> UUID? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2, components[0] == "preview" else { return nil }
        return UUID(uuidString: String(components[1]))
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

/// Client for the separately hosted, password-protected public Notes share.
/// The service expires every link after ten minutes and revokes prior links
/// immediately when a replacement is created.
final class PublicTextShareClient: ObservableObject {
    private static let apiBaseURL = URL(string: "https://helloipa-share.agile-fig-7406.chatgpt.site")!

    @Published private(set) var shareURL: URL?
    @Published private(set) var expiresAt: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPublishing = false

    private struct ImagePayload: Encodable {
        let dataBase64: String
        let mimeType: String
        let filename: String
    }

    private struct RequestPayload: Encodable {
        let text: String
        let password: String
        let images: [ImagePayload]
    }

    private struct ResponsePayload: Decodable {
        let shortCode: String
        let shareUrl: String
        let expiresAt: String?
    }

    func publish(text: String, images: [NoteImage], password: String) {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...8).contains(trimmedPassword.count) else {
            errorMessage = "公网分享访问密码必须为 1–8 个字符。"
            return
        }

        let payloadImages = images.compactMap { image -> ImagePayload? in
            // The public endpoint limits a single upload to 8 MB. The Notes
            // preview is a JPEG rendition created at insertion time, so it is
            // safe to transfer and still preserves the inline note image.
            guard let data = NoteImageStore.shared.previewData(for: image.id) else { return nil }
            return ImagePayload(
                dataBase64: data.base64EncodedString(),
                mimeType: "image/jpeg",
                filename: image.filename
            )
        }

        var request = URLRequest(url: Self.apiBaseURL.appendingPathComponent("api/shares"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 45

        do {
            request.httpBody = try JSONEncoder().encode(
                RequestPayload(text: text, password: trimmedPassword, images: payloadImages)
            )
        } catch {
            errorMessage = "无法准备公网分享内容。"
            return
        }

        errorMessage = nil
        isPublishing = true
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPublishing = false

                if let error = error as NSError? {
                    self.errorMessage = "无法连接公网分享服务（\(error.localizedDescription)）。"
                    return
                }

                guard let data = data, let http = response as? HTTPURLResponse else {
                    self.errorMessage = "公网分享服务没有返回有效响应。"
                    return
                }

                guard (200...299).contains(http.statusCode) else {
                    let serverMessage = Self.serverMessage(from: data)
                    switch http.statusCode {
                    case 413:
                        self.errorMessage = "图片或正文过大，公网服务拒绝了本次上传。"
                    case 401, 403:
                        self.errorMessage = "公网服务拒绝了本次创建请求（HTTP \(http.statusCode)）。"
                    default:
                        self.errorMessage = serverMessage ?? "公网服务返回错误（HTTP \(http.statusCode)）。"
                    }
                    return
                }

                guard let result = try? JSONDecoder().decode(ResponsePayload.self, from: data),
                      let url = URL(string: result.shareUrl) else {
                    self.errorMessage = "公网服务返回的数据无效。"
                    return
                }

                self.expiresAt = result.expiresAt
                self.shareURL = url
            }
        }.resume()
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["message"] as? String) ?? (object["error"] as? String)
    }

}

struct SharedNoteDocument: Equatable {
    let text: String
    let images: [NoteImage]
}

struct NoteImage: Identifiable, Codable, Equatable {
    var id = UUID()
    var location: Int
    var filename: String
    var mimeType: String
}

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var modifiedAt = Date()
    var images: [NoteImage] = []

    init(id: UUID = UUID(), text: String, modifiedAt: Date = Date(), images: [NoteImage] = []) {
        self.id = id
        self.text = text
        self.modifiedAt = modifiedAt
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case modifiedAt
        case images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        images = try container.decodeIfPresent([NoteImage].self, forKey: .images) ?? []
    }

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
            server.updateSharedDocument(text: text, images: currentNote.images)
        }
    }
    @Published var showingShareSheet = false
    @Published var showingList = true

    let server: LocalTextShareServer
    let publicShare = PublicTextShareClient()
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
        self.server = LocalTextShareServer(
            initialText: restoredNotes[0].text,
            initialImages: restoredNotes[0].images
        )

        server.$syncedDocument
            .receive(on: DispatchQueue.main)
            .sink { [weak self] document in
                guard let self = self,
                      self.text != document.text || self.currentNote.images != document.images else {
                    return
                }
                self.updateSelectedDocument(text: document.text, images: document.images)
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
        server.startSharing(text: text, images: currentNote.images)
        showingShareSheet = true
    }

    func stopSharing() {
        server.stopSharing()
        showingShareSheet = false
    }

    func publishPublicShare(password: String) {
        publicShare.publish(text: text, images: currentNote.images, password: password)
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
        notes[index].images.forEach { NoteImageStore.shared.removeImage(withID: $0.id) }
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

    func updateSelectedDocument(text newText: String, images: [NoteImage]) {
        guard let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        let changed = notes[index].text != newText || notes[index].images != images
        guard changed else { return }

        notes[index].images = images
        notes[index].text = newText
        notes[index].modifiedAt = Date()

        // The UIKit editor reports a complete document in one callback.  Persist
        // that model change here, rather than relying on `text.didSet`: by the
        // time that observer runs, the note has already been updated above and
        // it correctly treats the assignment as a no-op.
        persistNotes()
        server.updateSharedDocument(text: newText, images: images)

        if text != newText {
            text = newText
        }
    }

    private func updateSelectedNote() {
        guard let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        // Selecting a row assigns its existing text back into the editor.  That
        // is not an edit, so it must not turn the note's displayed modification
        // time into the current time.
        guard notes[index].text != text else { return }
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
    @ObservedObject var publicShare: PublicTextShareClient
    let publishPublicShare: (String) -> Void
    let onClose: () -> Void
    @State private var showingCopiedToast = false
    @State private var publicPassword = ""
    @State private var isPublicPasswordVisible = true

    var body: some View {
        VStack(spacing: 0) {
            OldOSNotesShareTitleBar(closeAction: onClose)

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color.retroPaper
                    if let paper = oldOSImage(named: "oldos-notes-body") {
                        paper.resizable().scaledToFill().clipped()
                    }

                    ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                    if let shareURL = server.shareURL {
                        Text("请让电脑和手机连接同一个 Wi-Fi，然后在浏览器打开下面这个地址：")
                            .font(.custom("Helvetica Neue Regular", size: 17))
                            .foregroundColor(Color.retroMetadata)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(shareURL.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.42))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.retroMetadata.opacity(0.55), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                        Button(action: copyAddress) {
                            HStack {
                                Image(systemName: "doc.on.doc")
                                Text("复制这个地址")
                            }
                            .font(.custom("Helvetica Neue Bold", size: 17))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                        }
                        .buttonStyle(GlossyCapsuleButtonStyle(baseColor: Color(red: 0.12, green: 0.34, blue: 0.67)))

                        Text("电脑打开后会看到当前正文中的文字和图片。")
                            .font(.footnote)
                            .foregroundColor(Color.retroMetadata)
                    } else if let errorMessage = server.errorMessage {
                        Text("分享启动失败")
                            .font(.headline)

                        Text(errorMessage)
                            .foregroundColor(Color(red: 0.62, green: 0.17, blue: 0.12))
                    } else {
                        HStack(spacing: 10) {
                            ActivityIndicator()
                            Text("正在启动局域网分享服务...")
                            .foregroundColor(Color.retroMetadata)
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider().background(Color.retroMetadata.opacity(0.35))

                    Text("公网限时分享")
                        .font(.custom("Helvetica Neue Bold", size: 18))
                        .foregroundColor(Color.retroMetadata)

                    Text("每次创建都会立即使旧公网链接失效；新链接固定 10 分钟有效，打开时必须输入密码。")
                        .font(.custom("Helvetica Neue Regular", size: 15))
                        .foregroundColor(Color.retroMetadata)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 0) {
                        Group {
                            if isPublicPasswordVisible {
                                // A normal text field intentionally keeps third-party
                                // keyboards available. iOS can restrict them for
                                // secure-entry fields such as SecureField.
                                TextField("设置访问密码", text: $publicPassword)
                            } else {
                                SecureField("设置访问密码", text: $publicPassword)
                            }
                        }
                        .font(.system(size: 16))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                        Button(isPublicPasswordVisible ? "隐藏" : "显示") {
                            isPublicPasswordVisible.toggle()
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.retroMetadata)
                        .padding(.leading, 10)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.48))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.retroMetadata.opacity(0.55), lineWidth: 1)
                    )
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .onChange(of: publicPassword) { value in
                            if value.count > 8 {
                                publicPassword = String(value.prefix(8))
                            }
                        }

                    Button(action: { publishPublicShare(publicPassword) }) {
                        HStack {
                            if publicShare.isPublishing { ActivityIndicator() }
                            Text("创建新的公网分享")
                        }
                        .font(.custom("Helvetica Neue Bold", size: 17))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                    }
                    .disabled(publicShare.isPublishing)
                    .buttonStyle(GlossyCapsuleButtonStyle(baseColor: Color(red: 0.12, green: 0.34, blue: 0.67)))

                    if let publicURL = publicShare.shareURL {
                        Text(publicURL.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.42))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.retroMetadata.opacity(0.55), lineWidth: 1)
                            )

                        if let expiresAt = publicShare.expiresAt {
                            Text("有效期至：\(expiresAt)")
                                .font(.footnote)
                                .foregroundColor(Color.retroMetadata)
                        } else {
                            Text("有效期为 10 分钟；创建新链接后，当前链接将立即失效。")
                                .font(.footnote)
                                .foregroundColor(Color.retroMetadata)
                        }

                        Button("复制公网地址") { copy(publicURL) }
                            .buttonStyle(GlossyCapsuleButtonStyle(baseColor: Color(red: 0.12, green: 0.34, blue: 0.67)))
                    }

                    if let publicError = publicShare.errorMessage {
                        Text(publicError)
                            .font(.footnote)
                            .foregroundColor(Color(red: 0.62, green: 0.17, blue: 0.12))
                    }
                    }
                    .padding(.bottom, 15)
                    }
                    // `frame(maxWidth: .infinity).padding(...)` grows beyond
                    // its parent on SwiftUI/iOS 13. Size the text column first
                    // and then add the margins so its outside edge is exactly
                    // the GeometryReader's edge.
                    .frame(
                        width: max(0, geometry.size.width - 40),
                        height: max(0, geometry.size.height - 39),
                        alignment: .topLeading
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 15)

                    if showingCopiedToast {
                        Text("已复制")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.82))
                            .clipShape(Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 12)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func copyAddress() {
        guard let shareURL = server.shareURL else { return }
        copy(shareURL)
    }

    private func copy(_ url: URL) {
        UIPasteboard.general.string = url.absoluteString
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
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            Spacer().frame(height: 5)
                            ForEach(viewModel.notes) { note in
                                Button(action: { viewModel.select(note) }) {
                                    HStack(spacing: 12) {
                                        Text(note.title)
                                            .font(.custom("Noteworthy-Bold", size: 18))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                        Text(dateFormatter.string(from: note.modifiedAt))
                                            .font(.custom("Helvetica Neue Regular", size: 14))
                                            .foregroundColor(Color(red: 99/255, green: 115/255, blue: 142/255))
                                            .fixedSize()
                                            .layoutPriority(1)
                                        if let next = oldOSImage(named: "oldos-notes-next") {
                                            next.renderingMode(.original).resizable().scaledToFit().frame(width: 15, height: 22).layoutPriority(1)
                                        }
                                    }
                                    .foregroundColor(Color(red: 160/255, green: 92/255, blue: 62/255))
                                    .padding(.horizontal, 12)
                                    .frame(width: geometry.size.width, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .frame(height: 44)
                                    .overlay(Rectangle().fill(Color(red: 78/255, green: 90/255, blue: 130/255).opacity(0.3)).frame(height: 1), alignment: .bottom)
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

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            // Keep the existing Notes layout within the safe area.  This layer
            // only becomes visible above it, behind the Dynamic Island/status
            // area, so the title bar's own 60pt position is unchanged.
            Color.retroLeatherDark
                .ignoresSafeArea(.container, edges: .top)
            OldOSNotesRootView(
                viewModel: viewModel,
                showingDeleteConfirmation: $showingDeleteConfirmation
            )
            if viewModel.showingShareSheet {
                ShareAddressSheet(
                    server: viewModel.server,
                    publicShare: viewModel.publicShare,
                    publishPublicShare: viewModel.publishPublicShare
                ) {
                    viewModel.showingShareSheet = false
                }
            }
        }
        .onAppear {
            viewModel.server.updateSharedDocument(
                text: viewModel.text,
                images: viewModel.currentNote.images
            )
        }
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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                RetroTitleBar(
                    title: viewModel.currentNote.title,
                    truncatesTitle: true,
                    leading: AnyView(
                        Button(action: { viewModel.showingList = true }) {
                            OldOSHeaderControl(title: "Notes", iconName: nil)
                                .frame(width: 55, height: 33)
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
                    Color.retroPaper
                    // OldOS uses bodyMarginThin-568h for the editor: unlike
                    // the list paper, this source image includes its left
                    // ruled-page margin.
                    if let paper = oldOSImage(named: "oldos-notes-body-margin") {
                        paper.resizable().scaledToFill().clipped()
                    }
                    StableTextEditor(
                        text: Binding(get: { viewModel.text }, set: { viewModel.text = $0 }),
                        metadata: editorMetadata
                    )
                    .frame(
                        width: geometry.size.width,
                        height: max(0, geometry.size.height - 60)
                    )

                    // The user-specified 200 physical-pixel margins are
                    // converted to points for the active Retina display.
                    HStack(spacing: 0) {
                        toolButton("oldos-previous", enabled: viewModel.canMovePrevious) { viewModel.moveSelection(by: -1) }
                        Spacer(minLength: 0)
                        toolButton(viewModel.server.isSharingEnabled ? "wifi.slash" : "wifi", enabled: true) { viewModel.server.isSharingEnabled ? viewModel.stopSharing() : viewModel.startSharing() }
                        Spacer(minLength: 0)
                        toolButton("oldos-trash", enabled: true) { showingDeleteConfirmation = true }
                        Spacer(minLength: 0)
                        toolButton("oldos-next", enabled: viewModel.canMoveNext) { viewModel.moveSelection(by: 1) }
                    }
                    .padding(.horizontal, physical200PixelInset)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, physical200PixelInset)
                }
                .frame(width: geometry.size.width, height: max(0, geometry.size.height - 60))
                .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
        }
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

    private var editorMetadata: NoteMetadata {
        let date = viewModel.currentNote.modifiedAt
        let dayCount = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: Date())).day ?? 0
        let relativeDate: String
        switch dayCount {
        case ...0: relativeDate = "Today"
        case 1: relativeDate = "1 day ago"
        default: relativeDate = "\(dayCount) days ago"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d  h:mm a"
        return NoteMetadata(relativeDate: relativeDate, timestamp: formatter.string(from: date))
    }

    private var physical200PixelInset: CGFloat {
        200 / UIScreen.main.scale
    }
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
