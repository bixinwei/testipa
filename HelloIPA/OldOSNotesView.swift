import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

final class NoteImageStore {
    static let shared = NoteImageStore()

    private let directoryURL: URL

    private init() {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        directoryURL = applicationSupport
            .appendingPathComponent("HelloIPA", isDirectory: true)
            .appendingPathComponent("NoteImages", isDirectory: true)
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func save(originalData: Data, previewData: Data, withID id: UUID) throws {
        try originalData.write(to: originalURL(for: id), options: .atomic)
        try previewData.write(to: previewURL(for: id), options: .atomic)
    }

    func originalData(for id: UUID) -> Data? {
        try? Data(contentsOf: originalURL(for: id), options: .mappedIfSafe)
    }

    func previewData(for id: UUID) -> Data? {
        try? Data(contentsOf: previewURL(for: id), options: .mappedIfSafe)
    }

    func previewImage(for id: UUID) -> UIImage? {
        guard let data = previewData(for: id) else { return nil }
        return UIImage(data: data)
    }

    func removeImage(withID id: UUID) {
        try? FileManager.default.removeItem(at: originalURL(for: id))
        try? FileManager.default.removeItem(at: previewURL(for: id))
    }

    private func originalURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).original", isDirectory: false)
    }

    private func previewURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).preview.jpg", isDirectory: false)
    }
}

struct PendingNoteImage: Identifiable, Equatable {
    let image: NoteImage
    var id: UUID { image.id }
}

private final class OldOSInlineImageAttachment: NSTextAttachment {
    let imageID: UUID

    init(imageID: UUID) {
        self.imageID = imageID
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

private enum OldOSNotesActionMenu: Int, Identifiable {
    case detailPlus
    case imageSource

    var id: Int { rawValue }
}

private enum OldOSNotesPicker: Int, Identifiable {
    case photoLibrary
    case files

    var id: Int { rawValue }
}

private struct OldOSNotesImageError: Identifiable {
    let id = UUID()
    let message: String
}

// This file intentionally keeps the view hierarchy from OldOS/Notes.swift.
// Only the Core Data bindings are adapted to AppViewModel, and the original
// mail toolbar action is replaced by this app's local Wi-Fi share action.

struct OldOSNotesRootView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var showingDeleteConfirmation: Bool
    @State private var forwardOrBackward = false
    @State private var isEditingNote = false
    @State private var activeMenu: OldOSNotesActionMenu?
    @State private var activePicker: OldOSNotesPicker?
    @State private var pendingImage: PendingNoteImage?
    @State private var imageError: OldOSNotesImageError?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                OldOSNotesTitleBar(
                    title: viewModel.showingList ? "Notes (\(viewModel.notes.filter { !$0.text.isEmpty }.count))" : viewModel.currentNote.title,
                    isDestination: !viewModel.showingList,
                    forwardOrBackward: forwardOrBackward,
                    backAction: {
                        isEditingNote = false
                        forwardOrBackward = true
                        withAnimation(.linear(duration: 0.28)) {
                            viewModel.showingList = true
                        }
                    },
                    newAction: {
                        forwardOrBackward = false
                        if viewModel.showingList {
                            pendingImage = nil
                            withAnimation(.linear(duration: 0.28)) {
                                viewModel.createNote()
                            }
                        } else {
                            activeMenu = .detailPlus
                        }
                    }
                )
                .frame(
                    minWidth: geometry.size.width,
                    maxWidth: geometry.size.width,
                    minHeight: 60,
                    maxHeight: 60
                )
                .zIndex(1)

                if viewModel.showingList {
                    OldOSNotesMainView(
                        viewModel: viewModel,
                        openNote: { note in
                            forwardOrBackward = false
                            pendingImage = nil
                            withAnimation(.linear(duration: 0.28)) {
                                viewModel.select(note)
                            }
                        }
                    )
                    .frame(width: geometry.size.width)
                    .transition(.asymmetric(
                        insertion: .move(edge: forwardOrBackward ? .leading : .trailing),
                        removal: .move(edge: forwardOrBackward ? .trailing : .leading)
                    ))
                    .clipped()
                } else {
                    OldOSNotesDestinationView(
                        viewModel: viewModel,
                        isEditingNote: $isEditingNote,
                        showingDeleteConfirmation: $showingDeleteConfirmation,
                        pendingImage: pendingImage
                    )
                    .frame(width: geometry.size.width)
                    .transition(.asymmetric(
                        insertion: .move(edge: forwardOrBackward ? .leading : .trailing),
                        removal: .move(edge: forwardOrBackward ? .trailing : .leading)
                    ))
                    .clipped()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .compositingGroup()
        .clipped()
        .confirmationDialog(
            activeMenu == .imageSource ? "选择图片来源" : "添加",
            isPresented: Binding(
                get: { activeMenu != nil },
                set: { isPresented in
                    if !isPresented {
                        activeMenu = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if activeMenu == .detailPlus {
                Button("新建备忘录") {
                    pendingImage = nil
                    withAnimation(.linear(duration: 0.28)) {
                        viewModel.createNote()
                    }
                }
                Button("插入图片") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        activeMenu = .imageSource
                    }
                }
            } else if activeMenu == .imageSource {
                Button("相册") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        activePicker = .photoLibrary
                    }
                }
                Button("剪贴板") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        insertImageFromClipboard()
                    }
                }
                Button("文件") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        activePicker = .files
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $activePicker) { picker in
            switch picker {
            case .photoLibrary:
                OldOSPhotoImagePicker(
                    completion: receivePickedImage
                )
            case .files:
                OldOSFileImagePicker(
                    completion: receivePickedImage
                )
            }
        }
        .alert(item: $imageError) { error in
            Alert(
                title: Text("无法插入图片"),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private func insertImageFromClipboard() {
        guard let image = UIPasteboard.general.image,
              let data = image.pngData() else {
            imageError = OldOSNotesImageError(message: "剪贴板中没有可用的图片。")
            return
        }
        receivePickedImage(data, "clipboard.png", "image/png")
    }

    private func receivePickedImage(_ data: Data, _ filename: String, _ mimeType: String) {
        guard let sourceImage = UIImage(data: data),
              let previewData = makePreviewData(from: sourceImage) else {
            imageError = OldOSNotesImageError(message: "所选文件不是受支持的图片，或图片数据已损坏。")
            return
        }

        let id = UUID()
        let cleanedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = NoteImage(
            id: id,
            location: 0,
            filename: cleanedFilename.isEmpty ? "image-\(id.uuidString).jpg" : cleanedFilename,
            mimeType: mimeType.isEmpty ? "application/octet-stream" : mimeType
        )

        do {
            try NoteImageStore.shared.save(
                originalData: data,
                previewData: previewData,
                withID: id
            )
            pendingImage = PendingNoteImage(image: image)
        } catch {
            imageError = OldOSNotesImageError(message: "图片无法保存到应用存储空间：\(error.localizedDescription)")
        }
    }

    private func makePreviewData(from image: UIImage) -> Data? {
        let maxDimension: CGFloat = 1_600
        let largestDimension = max(image.size.width, image.size.height)
        let scale = largestDimension > maxDimension ? maxDimension / largestDimension : 1
        let size = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.88)
    }
}

struct OldOSNotesMainView: View {
    @ObservedObject var viewModel: AppViewModel
    let openNote: (Note) -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "M/d/yy"
        return formatter
    }()

    private var notes: [Note] {
        viewModel.notes
            .filter { !$0.text.isEmpty }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        Spacer().frame(height: 5)
                        ForEach(notes) { note in
                            Button(action: { openNote(note) }) {
                                VStack(spacing: 0) {
                                    Spacer()
                                    HStack {
                                        Text(note.title)
                                            .font(.custom("Noteworthy-Bold", fixedSize: 18))
                                            .foregroundColor(Color(red: 160/255, green: 92/255, blue: 62/255))
                                            .lineLimit(1)
                                            .padding(.leading, 12)
                                        Spacer()
                                        Text(Self.dateFormatter.string(from: note.modifiedAt))
                                            .font(.custom("Helvetica Neue Regular", fixedSize: 14))
                                            .foregroundColor(Color(red: 99/255, green: 115/255, blue: 142/255))
                                            .padding(.trailing, 12)
                                        Image("UITableNext")
                                            .padding(.trailing, 12)
                                    }
                                    Spacer()
                                    Rectangle()
                                        .fill(Color(red: 78/255, green: 90/255, blue: 130/255).opacity(0.3))
                                        .frame(width: geometry.size.width, height: 1)
                                }
                                .frame(height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            .overlay(
                VStack {
                    Image("NotesEdgeTop")
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width)
                        .clipped()
                    Spacer()
                    Image("NotesEdgeBottom")
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width)
                        .clipped()
                }
            )
            .frame(width: geometry.size.width)
        }
        .background(Image("NotesBody").resizable().scaledToFill())
    }
}

struct OldOSNotesDestinationView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isEditingNote: Bool
    @Binding var showingDeleteConfirmation: Bool
    let pendingImage: PendingNoteImage?
    @ObservedObject private var keyboard = OldOSKeyboardResponder()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    OldOSNotesMultilineTextView(
                        text: viewModel.text,
                        images: viewModel.currentNote.images,
                        metadata: metadata,
                        isEditing: $isEditingNote,
                        pendingImage: pendingImage,
                        onDocumentChange: viewModel.updateSelectedDocument
                    )
                    .padding(.bottom, keyboard.currentHeight)
                    .edgesIgnoringSafeArea(.bottom)
                }
                .overlay(
                    VStack {
                        Image("edgeTopMarginThin")
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width + 4)
                            .clipped()
                        Spacer()
                        Image("gradBottomMarginThin")
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width + 4)
                            .clipped()
                    }
                )
                .overlay(
                    VStack {
                        Spacer()
                        HStack(spacing: 0) {
                            Spacer()
                            Button(action: { viewModel.moveSelection(by: -1) }) {
                                Image("arrow left")
                                    .opacity(viewModel.canMovePrevious ? 1 : 0.5)
                            }
                            .disabled(!viewModel.canMovePrevious)
                            Spacer()
                            Button(action: {
                                if viewModel.server.isSharingEnabled {
                                    viewModel.stopSharing()
                                } else {
                                    viewModel.startSharing()
                                }
                            }) {
                                Image(systemName: viewModel.server.isSharingEnabled ? "wifi.slash" : "wifi")
                                    .font(.system(size: 24, weight: .regular))
                                    .foregroundColor(Color(red: 113/255, green: 93/255, blue: 81/255))
                                    .frame(width: 32, height: 32)
                            }
                            Spacer()
                            Button(action: { showingDeleteConfirmation = true }) {
                                Image("trash")
                            }
                            Spacer()
                            Button(action: { viewModel.moveSelection(by: 1) }) {
                                Image("arrow right")
                                    .opacity(viewModel.canMoveNext ? 1 : 0.5)
                            }
                            .disabled(!viewModel.canMoveNext)
                            Spacer()
                        }
                        .padding(.bottom, 15)
                    }
                )
            }
        }
        // OldOS rendered this 320 pt-wide asset inside its shorter, simulated
        // device canvas. On a modern full-height screen, scaledToFill crops the
        // original 21–24 pt margin rules off both sides. Preserve the source
        // image's first 25 pt verbatim and stretch only the paper body.
        .background(
            Image("bodyMarginThin-568h")
                .resizable(
                    capInsets: EdgeInsets(top: 0, leading: 25, bottom: 0, trailing: 1),
                    resizingMode: .stretch
                )
        )
    }

    private var metadata: OldOSDestinationMetadata {
        let date = viewModel.currentNote.modifiedAt
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        let relativeDate: String
        if days == 0 {
            relativeDate = "Today"
        } else if days == 1 {
            relativeDate = "1 day ago"
        } else {
            relativeDate = "\(days) days ago"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d  h:mm a"
        return OldOSDestinationMetadata(relativeDate: relativeDate, timestamp: formatter.string(from: date))
    }
}

struct OldOSDestinationMetadata: Equatable {
    let relativeDate: String
    let timestamp: String
}

struct OldOSDestinationHeader: View {
    let metadata: OldOSDestinationMetadata

    var body: some View {
        HStack {
            Text(metadata.relativeDate)
                .font(.custom("Helvetica Neue Bold", fixedSize: 14))
                .foregroundColor(Color(red: 161/255, green: 93/255, blue: 68/255))
                .padding(.leading, 32)
            Spacer()
            Text(metadata.timestamp)
                .font(.custom("Helvetica Neue Regular", fixedSize: 14))
                .foregroundColor(Color(red: 161/255, green: 93/255, blue: 68/255))
                .padding(.trailing, 8)
        }
        .padding(.top, 10)
        .padding(.bottom, 15)
        .background(Color.clear)
    }
}

struct OldOSNotesMultilineTextView: UIViewRepresentable {
    let text: String
    let images: [NoteImage]
    let metadata: OldOSDestinationMetadata
    @Binding var isEditing: Bool
    let pendingImage: PendingNoteImage?
    let onDocumentChange: (String, [NoteImage]) -> Void

    private static let noteFont = UIFont(name: "Noteworthy-Bold", size: 19)
        ?? .systemFont(ofSize: 19, weight: .bold)

    private static let noteAttributes: [NSAttributedString.Key: Any] = [
        .font: noteFont,
        .foregroundColor: UIColor.black
    ]

    private static func styledText(
        _ value: String,
        images: [NoteImage],
        maxImageWidth: CGFloat
    ) -> NSAttributedString {
        let styled = NSMutableAttributedString(string: value, attributes: noteAttributes)
        let range = NSRange(value.startIndex..., in: value)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        detector?.enumerateMatches(in: value, options: [], range: range) { match, _, _ in
            guard let match = match, let url = match.url else { return }
            styled.addAttribute(.link, value: url, range: match.range)
        }

        for image in images.reversed() {
            let location = min(max(0, image.location), styled.length)
            styled.insert(
                attachmentString(for: image, maxImageWidth: maxImageWidth),
                at: location
            )
        }
        return styled
    }

    private static func attachmentString(
        for image: NoteImage,
        maxImageWidth: CGFloat
    ) -> NSAttributedString {
        let attachment = OldOSInlineImageAttachment(imageID: image.id)
        let preview = NoteImageStore.shared.previewImage(for: image.id)
            ?? UIImage(systemName: "photo")
            ?? UIImage()
        attachment.image = preview

        let sourceSize = preview.size
        let width = min(maxImageWidth, max(1, sourceSize.width))
        let ratio = sourceSize.width > 0 ? width / sourceSize.width : 1
        let height = max(1, sourceSize.height * ratio)
        attachment.bounds = CGRect(
            x: 0,
            y: noteFont.descender,
            width: width,
            height: height
        )
        return NSAttributedString(attachment: attachment)
    }

    private static func document(
        from attributedText: NSAttributedString,
        metadata: [UUID: NoteImage]
    ) -> (text: String, images: [NoteImage]) {
        var plainText = ""
        var plainUTF16Length = 0
        var extractedImages: [NoteImage] = []
        let fullRange = NSRange(location: 0, length: attributedText.length)

        attributedText.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? OldOSInlineImageAttachment,
               var image = metadata[attachment.imageID] {
                image.location = plainUTF16Length
                extractedImages.append(image)
                return
            }

            let segment = (attributedText.string as NSString).substring(with: range)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            plainText += segment
            plainUTF16Length += (segment as NSString).length
        }
        return (plainText, extractedImages)
    }

    private static func maximumImageWidth(in textView: UITextView) -> CGFloat {
        let viewWidth = textView.bounds.width > 0
            ? textView.bounds.width
            : UIScreen.main.bounds.width
        return max(
            80,
            viewWidth - textView.textContainerInset.left - textView.textContainerInset.right
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEditing: $isEditing,
            images: images,
            onDocumentChange: onDocumentChange
        )
    }

    func makeUIView(context: Context) -> DALinedTextView {
        let view = DALinedTextView()
        view.isScrollEnabled = true
        view.isEditable = true
        view.isUserInteractionEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.isOpaque = false
        view.overrideUserInterfaceStyle = .light
        view.font = Self.noteFont
        view.textColor = .black
        view.typingAttributes = Self.noteAttributes
        view.isSelectable = true
        view.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        view.delegate = context.coordinator
        view.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        view.tintColor = UIColor(red: 113/255, green: 93/255, blue: 81/255, alpha: 1)
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false

        let headerController = UIHostingController(rootView: OldOSDestinationHeader(metadata: metadata))
        let header = headerController.view!
        header.translatesAutoresizingMaskIntoConstraints = false
        header.backgroundColor = .clear
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leftAnchor.constraint(equalTo: view.leftAnchor),
            header.widthAnchor.constraint(equalTo: view.widthAnchor)
        ])
        context.coordinator.headerController = headerController

        view.textContainerInset = UIEdgeInsets(top: 40, left: 28, bottom: 30, right: 3)
        context.coordinator.imageMetadata = Dictionary(
            uniqueKeysWithValues: images.map { ($0.id, $0) }
        )
        view.attributedText = Self.styledText(
            text,
            images: images,
            maxImageWidth: Self.maximumImageWidth(in: view)
        )
        view.typingAttributes = Self.noteAttributes
        return view
    }

    func updateUIView(_ uiView: DALinedTextView, context: Context) {
        context.coordinator.headerController?.rootView = OldOSDestinationHeader(metadata: metadata)
        context.coordinator.onDocumentChange = onDocumentChange
        for image in images {
            context.coordinator.imageMetadata[image.id] = image
        }

        let currentDocument = Self.document(
            from: uiView.attributedText,
            metadata: context.coordinator.imageMetadata
        )
        if currentDocument.text != text || currentDocument.images != images {
            let selectedRange = uiView.selectedRange
            let contentOffset = uiView.contentOffset
            uiView.attributedText = Self.styledText(
                text,
                images: images,
                maxImageWidth: Self.maximumImageWidth(in: uiView)
            )
            uiView.typingAttributes = Self.noteAttributes
            let attributedLength = uiView.attributedText.length
            uiView.selectedRange = NSRange(
                location: min(selectedRange.location, attributedLength),
                length: 0
            )
            uiView.setContentOffset(contentOffset, animated: false)
        }

        if let pendingImage = pendingImage,
           context.coordinator.lastInsertedPendingID != pendingImage.id {
            context.coordinator.insert(pendingImage.image, into: uiView)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var isEditing: Bool
        var imageMetadata: [UUID: NoteImage]
        var onDocumentChange: (String, [NoteImage]) -> Void
        var lastInsertedPendingID: UUID?
        var headerController: UIHostingController<OldOSDestinationHeader>?

        init(
            isEditing: Binding<Bool>,
            images: [NoteImage],
            onDocumentChange: @escaping (String, [NoteImage]) -> Void
        ) {
            _isEditing = isEditing
            imageMetadata = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
            self.onDocumentChange = onDocumentChange
        }

        func textViewDidChange(_ textView: UITextView) {
            publishDocument(from: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            let document = OldOSNotesMultilineTextView.document(
                from: textView.attributedText,
                metadata: imageMetadata
            )
            imageMetadata = Dictionary(
                uniqueKeysWithValues: document.images.map { ($0.id, $0) }
            )
            let selectedRange = textView.selectedRange
            let contentOffset = textView.contentOffset
            textView.attributedText = OldOSNotesMultilineTextView.styledText(
                document.text,
                images: document.images,
                maxImageWidth: OldOSNotesMultilineTextView.maximumImageWidth(in: textView)
            )
            textView.typingAttributes = OldOSNotesMultilineTextView.noteAttributes
            textView.selectedRange = NSRange(
                location: min(selectedRange.location, textView.attributedText.length),
                length: 0
            )
            textView.setContentOffset(contentOffset, animated: false)
            onDocumentChange(document.text, document.images)
            isEditing = false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            textView.typingAttributes = OldOSNotesMultilineTextView.noteAttributes
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            scrollView.setNeedsDisplay()
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            UIApplication.shared.open(URL, options: [:], completionHandler: nil)
            return false
        }

        func insert(_ image: NoteImage, into textView: UITextView) {
            imageMetadata[image.id] = image
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let selectedRange = NSRange(
                location: min(textView.selectedRange.location, mutable.length),
                length: min(
                    textView.selectedRange.length,
                    max(0, mutable.length - min(textView.selectedRange.location, mutable.length))
                )
            )
            let payload = NSMutableAttributedString(string: "")
            if selectedRange.location > 0,
               (mutable.string as NSString).substring(
                with: NSRange(location: selectedRange.location - 1, length: 1)
               ) != "\n" {
                payload.append(NSAttributedString(string: "\n", attributes: OldOSNotesMultilineTextView.noteAttributes))
            }
            payload.append(
                OldOSNotesMultilineTextView.attachmentString(
                    for: image,
                    maxImageWidth: OldOSNotesMultilineTextView.maximumImageWidth(in: textView)
                )
            )
            payload.append(NSAttributedString(string: "\n", attributes: OldOSNotesMultilineTextView.noteAttributes))

            mutable.replaceCharacters(in: selectedRange, with: payload)
            textView.attributedText = mutable
            textView.typingAttributes = OldOSNotesMultilineTextView.noteAttributes
            textView.selectedRange = NSRange(
                location: selectedRange.location + payload.length,
                length: 0
            )
            lastInsertedPendingID = image.id
            publishDocument(from: textView)
        }

        private func publishDocument(from textView: UITextView) {
            let document = OldOSNotesMultilineTextView.document(
                from: textView.attributedText,
                metadata: imageMetadata
            )
            imageMetadata = Dictionary(
                uniqueKeysWithValues: document.images.map { ($0.id, $0) }
            )
            onDocumentChange(document.text, document.images)
        }
    }
}

struct OldOSNotesTitleBar: View {
    let title: String
    let isDestination: Bool
    let forwardOrBackward: Bool
    let backAction: () -> Void
    let newAction: () -> Void

    var body: some View {
        ZStack {
            Image("NotesTopBar").resizable()

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(title)
                        .font(.custom("Helvetica Neue Bold", fixedSize: 22))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.21), radius: 0, x: 0, y: -1)
                        .lineLimit(1)
                        .id(title)
                        .frame(maxWidth: isDestination ? 200 : .infinity)
                    Spacer()
                }
                Spacer()
            }

            if isDestination {
                VStack {
                    Spacer()
                    HStack {
                        Button(action: backAction) {
                            ZStack {
                                Image("NotesBack")
                                    .frame(width: 55, height: 33)
                                    .scaledToFill()
                                HStack(alignment: .center) {
                                    Text("Notes")
                                        .foregroundColor(.white)
                                        .font(.custom("Helvetica Neue Bold", fixedSize: 13))
                                        .shadow(color: Color.black.opacity(0.45), radius: 0, x: 0, y: -0.6)
                                        .padding(.leading, 5)
                                        .offset(y: -1.1)
                                }
                            }
                            .padding(.leading, 5)
                        }
                        Spacer()
                    }
                    Spacer()
                }
            }

            HStack {
                Spacer()
                OldOSNotesHeaderImageButton(imageName: "UIButtonBarPlus", action: newAction)
                    .padding(.trailing, 5)
            }
        }
    }
}

struct OldOSNotesHeaderImageButton: View {
    let imageName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image("header button")
                    .frame(width: 32, height: 32)
                    .scaledToFill()
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13)
                    .padding(.horizontal, 11)
            }
        }
        .frame(width: 32, height: 32)
    }
}

struct OldOSNotesHeaderTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image("header button")
                    .frame(width: 60, height: 32)
                    .scaledToFill()
                Text(title)
                    .font(.custom("Helvetica Neue Bold", fixedSize: 13.25))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.75), radius: 1, x: 0, y: -0.25)
                    .padding(.horizontal, 11)
            }
        }
        .frame(width: 60, height: 32)
    }
}

struct OldOSNotesShareTitleBar: View {
    let closeAction: () -> Void

    var body: some View {
        ZStack {
            Image("NotesTopBar").resizable()
            Text("共享地址")
                .font(.custom("Helvetica Neue Bold", fixedSize: 22))
                .foregroundColor(.white)
                .shadow(color: Color.black.opacity(0.21), radius: 0, x: 0, y: -1)
            HStack {
                Spacer()
                OldOSNotesHeaderTextButton(title: "完成", action: closeAction)
                    .padding(.trailing, 5)
            }
        }
        .frame(height: 60)
    }
}

struct OldOSPhotoImagePicker: UIViewControllerRepresentable {
    let completion: (Data, String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (Data, String, String) -> Void

        init(completion: @escaping (Data, String, String) -> Void) {
            self.completion = completion
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            let contentType = provider.registeredTypeIdentifiers
                .compactMap { UTType($0) }
                .first { $0.conforms(to: .image) }
            let typeIdentifier = contentType?.identifier ?? UTType.image.identifier
            let filename = provider.suggestedName
                ?? "photo.\(contentType?.preferredFilenameExtension ?? "jpg")"
            let mimeType = contentType?.preferredMIMEType ?? "application/octet-stream"

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data = data else { return }
                DispatchQueue.main.async {
                    self.completion(data, filename, mimeType)
                }
            }
        }
    }
}

struct OldOSFileImagePicker: UIViewControllerRepresentable {
    let completion: (Data, String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.image],
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Data, String, String) -> Void

        init(completion: @escaping (Data, String, String) -> Void) {
            self.completion = completion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
            let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            let fallbackType = UTType(filenameExtension: url.pathExtension)
            let mimeType = contentType?.preferredMIMEType
                ?? fallbackType?.preferredMIMEType
                ?? "application/octet-stream"
            completion(data, url.lastPathComponent, mimeType)
        }
    }
}

final class OldOSKeyboardResponder: ObservableObject {
    @Published private(set) var currentHeight: CGFloat = 0
    private let notificationCenter: NotificationCenter

    init(center: NotificationCenter = .default) {
        notificationCenter = center
        center.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    @objc private func keyboardWillShow(notification: Notification) {
        if let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            currentHeight = frame.height
        }
    }

    @objc private func keyboardWillHide(notification: Notification) {
        currentHeight = 0
    }
}
