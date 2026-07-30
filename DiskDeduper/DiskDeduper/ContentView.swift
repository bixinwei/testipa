import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var scanner: DuplicateScanner
    @State private var showingImporter = false
    @State private var selectedPreview: DiskFile?

    var body: some View {
        NavigationStack {
            Group {
                if scanner.groups.isEmpty && !scanner.isScanning {
                    EmptyState(
                        title: "尚未发现重复文件",
                        symbol: "externaldrive.badge.magnifyingglass",
                        message: scanner.rootURL == nil ? "选择移动硬盘中的文件夹后开始扫描。" : "点击扫描，按 \(scanner.mode.rawValue) 查找重复文件。"
                    )
                } else {
                    List {
                        if scanner.isScanning {
                            Section {
                                HStack { ProgressView(); Text("正在扫描文件…") }
                            }
                        }
                        if !scanner.groups.isEmpty {
                            Section("扫描结果") {
                                LabeledContent("已枚举") { Text("\(scanner.scannedFiles) 个") }
                                LabeledContent("复用缓存") { Text("\(scanner.reusedHashes) 个") }
                                LabeledContent("本次 MD5") { Text("\(scanner.newlyHashed) 个") }
                                if scanner.pendingHashes > 0 {
                                    LabeledContent("待下次校验") { Text("\(scanner.pendingHashes) 个") }
                                }
                                LabeledContent("重复文件") { Text("\(scanner.totalDuplicates) 个") }
                                LabeledContent("可释放空间") { Text(scanner.recoverableSpace.formattedSize) }
                            }
                            ForEach(scanner.groups) { group in
                                NavigationLink(value: group) { GroupRow(group: group) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("磁盘去重")
            .navigationDestination(for: DuplicateGroup.self) { group in
                DuplicateGroupView(group: group, selectedPreview: $selectedPreview)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("匹配方式", selection: $scanner.mode) {
                            ForEach(MatchingMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("本次新文件校验", selection: $scanner.scanLimit) {
                            ForEach(ScanLimit.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Image(systemName: "slider.horizontal.3") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImporter = true } label: { Image(systemName: "folder.badge.plus") }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { scanner.scan() } label: {
                        Label(scanner.isScanning ? "扫描中" : "开始扫描", systemImage: "magnifyingglass")
                    }
                    .disabled(scanner.isScanning || scanner.rootURL == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let root = scanner.rootURL {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前范围：\(root.lastPathComponent)").font(.footnote.weight(.semibold))
                        Text(scanner.mode.explanatoryText).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.bar)
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): scanner.setRoot(url)
            case .failure(let error): scanner.errorMessage = "选择文件夹失败：\(error.localizedDescription)"
            }
        }
        .alert("操作提示", isPresented: Binding(get: { scanner.errorMessage != nil }, set: { if !$0 { scanner.errorMessage = nil } })) {
            Button("好", role: .cancel) { scanner.errorMessage = nil }
        } message: { Text(scanner.errorMessage ?? "") }
        .alert(item: $scanner.feedback) { feedback in
            Alert(
                title: Text(feedback.title),
                message: Text(feedback.message),
                dismissButton: .default(Text("好"))
            )
        }
        .sheet(item: $selectedPreview) { file in FilePreviewSheet(file: file) }
    }
}

private struct GroupRow: View {
    let group: DuplicateGroup
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.files.first?.filename ?? "重复文件").lineLimit(1)
                Text("\(group.files.count) 个副本 · 每个 \((group.files.first?.size ?? 0).formattedSize)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("释放\n\(group.spaceToRecover.formattedSize)")
                .font(.caption2).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
        }
    }
    private var icon: String {
        switch group.files.first?.type {
        case .some(.image): return "photo"
        case .some(.video): return "film"
        default: return "doc"
        }
    }
}

private struct DuplicateGroupView: View {
    @EnvironmentObject private var scanner: DuplicateScanner
    @Environment(\.dismiss) private var dismiss
    let group: DuplicateGroup
    @Binding var selectedPreview: DiskFile?
    @State private var selected: Set<String>
    @State private var showingDeleteConfirmation = false

    init(group: DuplicateGroup, selectedPreview: Binding<DiskFile?>) {
        self.group = group
        _selectedPreview = selectedPreview
        _selected = State(initialValue: Set(group.files.dropFirst().map(\.id)))
    }

    var body: some View {
        List {
            Section("相同文件") {
                Text("已按 \(scanner.mode.rawValue) 匹配。默认保留第一份，勾选其余文件后可删除或忽略。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(group.files) { file in
                    FileRow(file: file, isSelected: selected.contains(file.id)) {
                        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
                    } onPreview: { selectedPreview = file }
                }
            }
        }
        .navigationTitle("\(group.files.count) 个重复文件")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("忽略选中") {
                    scanner.ignore(selectedFiles)
                    dismiss()
                }.disabled(selectedFiles.isEmpty)
                Spacer()
                Button("删除选中", role: .destructive) { showingDeleteConfirmation = true }.disabled(selectedFiles.isEmpty)
            }
        }
        .confirmationDialog("删除 \(selectedFiles.count) 个重复文件？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                scanner.delete(selectedFiles)
                dismiss()
            }
        } message: { Text("文件会从移动硬盘中永久删除，无法恢复。") }
    }

    private var selectedFiles: [DiskFile] { group.files.filter { selected.contains($0.id) } }
}

private struct FileRow: View {
    let file: DiskFile
    let isSelected: Bool
    let toggle: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundColor(isSelected ? .accentColor : .secondary)
            }.buttonStyle(.plain)
            PreviewThumbnail(file: file).onTapGesture(perform: onPreview)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.filename).lineLimit(2)
                Text(file.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(file.size.formattedSize).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard file.type != .file else { return }
            onPreview()
        }
    }
}

private struct PreviewThumbnail: View {
    let file: DiskFile
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
            else { Image(systemName: file.type == .video ? "film" : "doc").font(.title2).foregroundStyle(.secondary) }
        }
        .frame(width: 60, height: 60).background(Color.secondary.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: file.id) {
            thumbnail = FilePreview.thumbnail(for: file)
        }
    }
}

private struct FilePreviewSheet: View {
    let file: DiskFile
    var body: some View {
        NavigationStack {
            Group {
                if file.type == .image, let image = UIImage(contentsOfFile: file.path) { Image(uiImage: image).resizable().scaledToFit().padding() }
                else if file.type == .video { VideoPlayer(player: AVPlayer(url: file.url)) }
                else { EmptyState(title: "无法预览", symbol: "doc", message: file.filename) }
            }
            .navigationTitle(file.filename).navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct EmptyState: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

private extension Int64 {
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
