import SwiftUI
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers

final class NoteImageStore {
    static let shared = NoteImageStore()

    private let directoryURL: URL
    private let renderedPreviewCache = NSCache<NSString, UIImage>()

    private init() {
        renderedPreviewCache.countLimit = 16
        renderedPreviewCache.totalCostLimit = 48 * 1_024 * 1_024
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
        renderedPreviewCache.removeAllObjects()
    }

    func originalData(for id: UUID) -> Data? {
        try? Data(contentsOf: originalURL(for: id), options: .mappedIfSafe)
    }

    func previewData(for id: UUID) -> Data? {
        try? Data(contentsOf: previewURL(for: id), options: .mappedIfSafe)
    }

    func makePreviewData(from image: UIImage) -> Data? {
        let maxDimension: CGFloat = 1_600
        let largestDimension = max(image.size.width, image.size.height)
        let scale = largestDimension > maxDimension ? maxDimension / largestDimension : 1
        let size = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )
        let renderer = UIGraphicsImageRenderer(size: size)
        let preview = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return preview.jpegData(compressionQuality: 0.84)
    }

    func previewImage(for id: UUID) -> UIImage? {
        guard let data = previewData(for: id) else { return nil }
        // Preview JPEGs have no UIKit scale metadata. Treating them as 1×
        // makes a 1600 px image look 1600 pt wide, so NSTextAttachment must
        // continuously downscale a huge texture while scrolling on a 3× phone.
        // Decode at the active screen scale so its point size matches the
        // actual display density before attachment layout begins.
        return UIImage(data: data, scale: UIScreen.main.scale)
    }

    func renderedPreview(for id: UUID, maximumPointWidth: CGFloat) -> UIImage? {
        let scale = UIScreen.main.scale
        let targetPixelWidth = max(1, Int((maximumPointWidth * scale).rounded(.up)))
        let cacheKey = "\(id.uuidString)-\(targetPixelWidth)" as NSString
        if let cached = renderedPreviewCache.object(forKey: cacheKey) {
            return cached
        }
        guard let source = previewImage(for: id) else { return nil }

        let displayWidth = min(maximumPointWidth, source.size.width)
        let ratio = source.size.width > 0 ? displayWidth / source.size.width : 1
        let displaySize = CGSize(
            width: max(1, displayWidth),
            height: max(1, source.size.height * ratio)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: displaySize, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: displaySize))
        }
        let pixelWidth = Int((rendered.size.width * rendered.scale).rounded(.up))
        let pixelHeight = Int((rendered.size.height * rendered.scale).rounded(.up))
        renderedPreviewCache.setObject(
            rendered,
            forKey: cacheKey,
            cost: pixelWidth * pixelHeight * 4
        )
        return rendered
    }

    func removeImage(withID id: UUID) {
        try? FileManager.default.removeItem(at: originalURL(for: id))
        try? FileManager.default.removeItem(at: previewURL(for: id))
        renderedPreviewCache.removeAllObjects()
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

private extension NSAttributedString.Key {
    // Keep application metadata alongside a stock NSTextAttachment. TextKit is
    // free to copy and archive the attachment while laying out a caret, so the
    // identifier must not depend on an incomplete attachment subclass.
    static let helloIPANoteImageID = NSAttributedString.Key("HelloIPA.NoteImageID")
}

private class ImageSafeTextView: DALinedTextView {
    private static let attachmentCharacter: unichar = 0xFFFC

    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let proposed = super.closestPosition(to: point) else { return nil }
        let location = offset(from: beginningOfDocument, to: proposed)
        let text = attributedText.string as NSString
        guard location >= 0, location <= text.length else { return proposed }

        // A tap in the empty space to the right of an image normally resolves
        // to one of the two insertion positions around U+FFFC. Both positions
        // are attachment boundaries, not editable text. Move that tap to the
        // first character of the following line instead.
        let touchesAttachment =
            (location < text.length && text.character(at: location) == Self.attachmentCharacter)
            || (location > 0 && text.character(at: location - 1) == Self.attachmentCharacter)
        guard touchesAttachment else { return proposed }

        let searchRange = NSRange(location: min(location, text.length), length: text.length - min(location, text.length))
        let nextLine = text.range(of: "\n", options: [], range: searchRange)
        let destination = nextLine.location == NSNotFound ? text.length : nextLine.location + 1
        return position(from: beginningOfDocument, offset: destination) ?? proposed
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
                    title: viewModel.showingList ? "Notes (\(viewModel.notes.count))" : viewModel.currentNote.title,
                    isDestination: !viewModel.showingList,
                    forwardOrBackward: forwardOrBackward,
                    backAction: {
                        viewModel.persistText()
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
                Button("最近照片") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        insertMostRecentPhoto()
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

    private func insertMostRecentPhoto() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            loadMostRecentPhoto()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    guard newStatus == .authorized || newStatus == .limited else {
                        imageError = OldOSNotesImageError(message: "需要允许访问照片，才能插入最近照片。")
                        return
                    }
                    loadMostRecentPhoto()
                }
            }
        default:
            imageError = OldOSNotesImageError(message: "请在系统设置中允许访问照片，才能插入最近照片。")
        }
    }

    private func loadMostRecentPhoto() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.fetchLimit = 1
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        guard let asset = PHAsset.fetchAssets(with: .image, options: fetchOptions).firstObject else {
            imageError = OldOSNotesImageError(message: "照片图库中没有可插入的图片。")
            return
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        PHImageManager.default().requestImageDataAndOrientation(
            for: asset,
            options: options
        ) { data, dataUTI, _, _ in
            DispatchQueue.main.async {
                guard let data else {
                    imageError = OldOSNotesImageError(message: "无法读取最近照片，请稍后重试。")
                    return
                }
                let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
                    ?? "recent-photo.jpg"
                let mimeType = dataUTI.flatMap { UTType($0)?.preferredMIMEType }
                    ?? "image/jpeg"
                receivePickedImage(data, filename, mimeType)
            }
        }
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
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                OldOSNotesMultilineTextView(
                    documentID: viewModel.currentNote.id,
                    text: viewModel.text,
                    images: viewModel.currentNote.images,
                    metadata: metadata,
                    isEditing: $isEditingNote,
                    pendingImage: pendingImage,
                    onDocumentChange: viewModel.updateSelectedDocument,
                    onCommit: viewModel.persistText
                )
                .frame(maxHeight: .infinity)

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
                                    // Closing the address page leaves the local server running.
                                    // Reopen that page on the next tap instead of treating the
                                    // first tap as an invisible stop operation.
                                    viewModel.showingShareSheet = true
                                } else {
                                    viewModel.startSharing()
                                }
                            }) {
                                OldOSNotesWiFiStatusIcon(
                                    isSharing: viewModel.server.isSharingEnabled
                                )
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
                .frame(height: 48)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            // The editor and toolbar share this one page background. The
            // toolbar is in normal layout below the editor, so text cannot
            // scroll beneath it and the paper texture remains continuous.
            .background(alignment: .bottom) {
                Image("gradBottomMarginThin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width + 4)
                    .clipped()
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
        let relativeDate: String
        if Calendar.current.isDateInToday(date) {
            relativeDate = "Today"
        } else {
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.locale = Locale(identifier: "en_US")
            weekdayFormatter.dateFormat = "EEEE"
            relativeDate = weekdayFormatter.string(from: date)
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
    let documentID: UUID
    let text: String
    let images: [NoteImage]
    let metadata: OldOSDestinationMetadata
    @Binding var isEditing: Bool
    let pendingImage: PendingNoteImage?
    let onDocumentChange: (String, [NoteImage]) -> Void
    let onCommit: () -> Void

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
        let attachment = NSTextAttachment()
        let sourcePreview = NoteImageStore.shared.renderedPreview(
            for: image.id,
            maximumPointWidth: maxImageWidth
        )
            ?? UIImage(systemName: "photo")
            ?? UIImage()
        // `renderedPreview` is already decoded and scaled to the attachment's
        // final display width. Scrolling therefore reuses this bitmap instead
        // of resampling the original preview texture every frame.
        let preview = sourcePreview
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
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(
            .helloIPANoteImageID,
            value: image.id.uuidString,
            range: NSRange(location: 0, length: result.length)
        )
        return result
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
            if attributes[.attachment] is NSTextAttachment,
               let imageID = attributes[.helloIPANoteImageID] as? String,
               let id = UUID(uuidString: imageID),
               var image = metadata[id] {
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
        let contentWidth = max(
            1,
            viewWidth - textView.textContainerInset.left - textView.textContainerInset.right
        )
        return contentWidth * 0.8
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentID: documentID,
            isEditing: $isEditing,
            images: images,
            onDocumentChange: onDocumentChange,
            onCommit: onCommit
        )
    }

    func makeUIView(context: Context) -> DALinedTextView {
        let view = ImageSafeTextView()
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
        context.coordinator.installKeyboardAvoidance(on: view)
        context.coordinator.installLineRefresh(on: view)
        context.coordinator.imageMetadata = Dictionary(
            uniqueKeysWithValues: images.map { ($0.id, $0) }
        )
        view.attributedText = Self.styledText(
            text,
            images: images,
            maxImageWidth: Self.maximumImageWidth(in: view)
        )
        view.typingAttributes = Self.noteAttributes
        context.coordinator.recordAppliedDocument(text: text, images: images)
        return view
    }

    func updateUIView(_ uiView: DALinedTextView, context: Context) {
        context.coordinator.headerController?.rootView = OldOSDestinationHeader(metadata: metadata)
        context.coordinator.onDocumentChange = onDocumentChange
        context.coordinator.onCommit = onCommit

        // A SwiftUI transition can retain the same UITextView while the model
        // has already switched from note A to B. Never let the old active edit
        // session suppress that document replacement, or A's attachment layer
        // remains on screen and flickers through B.
        if context.coordinator.documentID != documentID {
            uiView.resignFirstResponder()
            context.coordinator.isUserEditingSession = false
            context.coordinator.isApplyingModelDocument = true
            context.coordinator.imageMetadata = Dictionary(
                uniqueKeysWithValues: images.map { ($0.id, $0) }
            )
            uiView.attributedText = Self.styledText(
                text,
                images: images,
                maxImageWidth: Self.maximumImageWidth(in: uiView)
            )
            uiView.typingAttributes = Self.noteAttributes
            uiView.selectedRange = NSRange(location: 0, length: 0)
            uiView.setContentOffset(.zero, animated: false)
            context.coordinator.isApplyingModelDocument = false
            context.coordinator.documentID = documentID
            context.coordinator.lastInsertedPendingID = nil
            context.coordinator.recordAppliedDocument(text: text, images: images)
            isEditing = false
            return
        }
        for image in images {
            context.coordinator.imageMetadata[image.id] = image
        }

        // UITextView owns its text storage for an active edit session. SwiftUI
        // publishes `notes`, `text`, and the modified date separately; applying
        // one of those intermediate snapshots back into an attachment-backed
        // text view is what made the caret after an image repeatedly relayout
        // and crash. Reconcile only when UIKit is not actively editing.
        if !context.coordinator.isUserEditingSession {
            let currentDocument = Self.document(
                from: uiView.attributedText,
                metadata: context.coordinator.imageMetadata
            )
            if currentDocument.text != text || currentDocument.images != images {
            let selectedRange = uiView.selectedRange
            let contentOffset = uiView.contentOffset
            context.coordinator.isApplyingModelDocument = true
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
            context.coordinator.isApplyingModelDocument = false
            }
            context.coordinator.recordAppliedDocument(text: text, images: images)
        }

        if let pendingImage = pendingImage,
           context.coordinator.lastInsertedPendingID != pendingImage.id {
            context.coordinator.insert(pendingImage.image, into: uiView)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var isEditing: Bool
        var documentID: UUID
        var imageMetadata: [UUID: NoteImage]
        var onDocumentChange: (String, [NoteImage]) -> Void
        var onCommit: () -> Void
        var lastInsertedPendingID: UUID?
        var headerController: UIHostingController<OldOSDestinationHeader>?
        var isApplyingModelDocument = false
        var isUserEditingSession = false
        private var lastPublishedText = ""
        private var lastPublishedImages: [NoteImage] = []
        private weak var keyboardTextView: UITextView?
        private var keyboardObservers: [NSObjectProtocol] = []
        private var baseContentInset = UIEdgeInsets.zero
        private weak var linedTextView: DALinedTextView?
        private var lineRefreshLink: CADisplayLink?
        private var needsLineRefresh = false

        init(
            documentID: UUID,
            isEditing: Binding<Bool>,
            images: [NoteImage],
            onDocumentChange: @escaping (String, [NoteImage]) -> Void,
            onCommit: @escaping () -> Void
        ) {
            self.documentID = documentID
            _isEditing = isEditing
            imageMetadata = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
            self.onDocumentChange = onDocumentChange
            self.onCommit = onCommit
        }

        deinit {
            keyboardObservers.forEach(NotificationCenter.default.removeObserver)
            lineRefreshLink?.invalidate()
        }

        // DALinedTextView's paper rules must track contentOffset, but asking it
        // to redraw from every UIScrollView callback can schedule several full
        // view redraws in one display frame. Coalesce those callbacks onto the
        // display's own cadence, including ProMotion's maximum refresh rate.
        func installLineRefresh(on textView: DALinedTextView) {
            guard lineRefreshLink == nil else { return }
            linedTextView = textView
            let link = CADisplayLink(target: self, selector: #selector(refreshPaperRules))
            if #available(iOS 15.0, *) {
                let maximum = Float(UIScreen.main.maximumFramesPerSecond)
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60,
                    maximum: maximum,
                    preferred: maximum
                )
            } else {
                link.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
            }
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            lineRefreshLink = link
        }

        @objc private func refreshPaperRules() {
            guard needsLineRefresh, let linedTextView else {
                lineRefreshLink?.isPaused = true
                return
            }
            needsLineRefresh = false
            linedTextView.setNeedsDisplay()
        }

        // UITextView is already a scroll view. Keep its frame and text layout
        // untouched, and use the documented scroll-view content inset to make
        // the active line visible above the keyboard.
        func installKeyboardAvoidance(on textView: UITextView) {
            guard keyboardTextView == nil else { return }
            keyboardTextView = textView
            baseContentInset = textView.contentInset
            let center = NotificationCenter.default
            let handler: (Notification) -> Void = { [weak self, weak textView] notification in
                guard let self, let textView else { return }
                self.updateKeyboardAvoidance(for: textView, notification: notification)
            }
            let didShowHandler: (Notification) -> Void = { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                self.revealCaretAfterKeyboardPresentation(in: textView)
            }
            keyboardObservers = [
                center.addObserver(
                    forName: UIResponder.keyboardWillChangeFrameNotification,
                    object: nil,
                    queue: .main,
                    using: handler
                ),
                center.addObserver(
                    forName: UIResponder.keyboardWillHideNotification,
                    object: nil,
                    queue: .main,
                    using: handler
                ),
                center.addObserver(
                    forName: UIResponder.keyboardDidShowNotification,
                    object: nil,
                    queue: .main,
                    using: didShowHandler
                )
            ]
        }

        private func updateKeyboardAvoidance(for textView: UITextView, notification: Notification) {
            guard let window = textView.window,
                  let keyboardFrameInScreen = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
                return
            }
            let keyboardFrame = window.convert(keyboardFrameInScreen, from: nil)
            let textViewFrame = textView.convert(textView.bounds, to: window)
            let overlap = max(0, textViewFrame.intersection(keyboardFrame).height)
            var inset = baseContentInset
            inset.bottom += overlap
            textView.contentInset = inset
            textView.verticalScrollIndicatorInsets = inset

        }

        private func revealCaretAfterKeyboardPresentation(in textView: UITextView) {
            guard textView.isFirstResponder else { return }
            // Do not change contentOffset while a third-party keyboard is
            // negotiating its own presentation frame. At this point UIKit has
            // completed that transition, so revealing the caret cannot feed
            // back into keyboard sizing or produce a blank keyboard area.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            publishDocument(from: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            // Keep the insertion attributes on the UIKit editing boundary.  Do
            // not assign them from a selection-change callback: TextKit can
            // re-enter selection/layout while the caret is next to an
            // NSTextAttachment.
            textView.typingAttributes = OldOSNotesMultilineTextView.noteAttributes
            isUserEditingSession = true
            isEditing = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            // Replacing attributedText while TextKit is resigning first
            // responder invalidates attachment layout and can leave a caret
            // beside an image without an input view.  The text storage is
            // already canonical; publish it without rebuilding it.
            publishDocument(from: textView)
            isUserEditingSession = false
            onCommit()
            isEditing = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView === linedTextView else { return }
            needsLineRefresh = true
            lineRefreshLink?.isPaused = false
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacementText: String
        ) -> Bool {
            // The insertion point after an image lives on the next line. Make
            // Backspace there remove the image block as one unit, rather than
            // allowing UITextView to step back onto the attachment boundary.
            guard replacementText.isEmpty, range.length == 1 else { return true }
            let text = textView.attributedText.string as NSString
            guard range.location >= 1, range.location < text.length,
                  text.character(at: range.location) == 0x0A,
                  text.character(at: range.location - 1) == 0xFFFC else {
                return true
            }

            textView.textStorage.replaceCharacters(
                in: NSRange(location: range.location - 1, length: 2),
                with: ""
            )
            textView.selectedRange = NSRange(location: range.location - 1, length: 0)
            publishDocument(from: textView)
            return false
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
            // An image picker normally leaves the text view without first
            // responder status. Re-enter the standard UITextView editing
            // session before mutating its attachment-backed text storage, so
            // the newly inserted image and the following caret share one
            // stable TextKit layout and UIKit presents the keyboard normally.
            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }
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
            textView.textStorage.setAttributedString(mutable)
            textView.typingAttributes = OldOSNotesMultilineTextView.noteAttributes
            textView.selectedRange = NSRange(
                location: selectedRange.location + payload.length,
                length: 0
            )
            lastInsertedPendingID = image.id
            publishDocument(from: textView)
        }

        private func publishDocument(from textView: UITextView) {
            guard !isApplyingModelDocument else { return }
            let document = OldOSNotesMultilineTextView.document(
                from: textView.attributedText,
                metadata: imageMetadata
            )
            imageMetadata = Dictionary(
                uniqueKeysWithValues: document.images.map { ($0.id, $0) }
            )
            guard document.text != lastPublishedText || document.images != lastPublishedImages else {
                return
            }
            lastPublishedText = document.text
            lastPublishedImages = document.images
            onDocumentChange(document.text, document.images)
        }

        func recordAppliedDocument(text: String, images: [NoteImage]) {
            lastPublishedText = text
            lastPublishedImages = images
        }

        func commitIfNeeded() {
            onCommit()
        }
    }

    static func dismantleUIView(_ uiView: DALinedTextView, coordinator: Coordinator) {
        coordinator.commitIfNeeded()
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

/// A hand-drawn sharing-state icon. The enabled state uses the existing bitmap;
/// the default disabled state adds a matching round-capped interruption stroke.
struct OldOSNotesWiFiStatusIcon: View {
    let isSharing: Bool

    var body: some View {
        ZStack {
            Image("NotesWiFiShare")
                .resizable()
                .scaledToFit()

            if !isSharing {
                Path { path in
                    path.move(to: CGPoint(x: 6, y: 5))
                    path.addLine(to: CGPoint(x: 27, y: 27))
                }
                .stroke(
                    Color(red: 138 / 255, green: 73 / 255, blue: 47 / 255),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityLabel(isSharing ? "分享已开启" : "分享未开启")
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
            // This overlay sits above the still-visible detail page, so unlike
            // the main title bar it needs its own opaque background.
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
