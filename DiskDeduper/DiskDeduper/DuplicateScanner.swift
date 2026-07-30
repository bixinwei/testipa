import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import UIKit

enum MatchingMode: String, CaseIterable, Identifiable {
    case fileSize = "文件大小"
    case md5 = "MD5 内容"

    var id: Self { self }
    var explanatoryText: String {
        switch self {
        case .fileSize: return "快速找出大小相同的文件；内容不一定相同。"
        case .md5: return "逐个读取候选文件并计算 MD5；结果准确但耗时更长。"
        }
    }
}

struct DiskFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let type: FileKind

    var id: String { url.path }
    var filename: String { url.lastPathComponent }
    var path: String { url.path }

    enum FileKind: String, Hashable, Sendable {
        case image, video, file
    }
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let key: String
    let files: [DiskFile]

    var id: String { key }
    var spaceToRecover: Int64 { Int64(max(0, files.count - 1)) * (files.first?.size ?? 0) }
}

@MainActor
final class DuplicateScanner: ObservableObject {
    @Published var rootURL: URL?
    @Published var groups: [DuplicateGroup] = []
    @Published var mode: MatchingMode = .md5
    @Published var isScanning = false
    @Published var scannedFiles = 0
    @Published var errorMessage: String?

    private let ignoredDefaultsKey = "DiskDeduper.ignoredPaths"
    private let bookmarkDefaultsKey = "DiskDeduper.rootBookmark"
    private var ignoredPaths: Set<String> = []
    private var accessedRootURL: URL?

    init() {
        ignoredPaths = Set(UserDefaults.standard.stringArray(forKey: ignoredDefaultsKey) ?? [])
        restoreRoot()
    }

    var totalDuplicates: Int { groups.reduce(0) { $0 + max(0, $1.files.count - 1) } }
    var recoverableSpace: Int64 { groups.reduce(0) { $0 + $1.spaceToRecover } }

    func setRoot(_ url: URL) {
        stopAccessingRoot()
        rootURL = url
        beginAccessingRoot(url)
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkDefaultsKey)
        } catch {
            errorMessage = "无法保存该文件夹的访问授权：\(error.localizedDescription)"
        }
    }

    func scan() {
        guard let rootURL else {
            errorMessage = "请先选择移动硬盘中的根文件夹。"
            return
        }
        isScanning = true
        groups = []
        scannedFiles = 0
        let mode = mode
        let ignored = ignoredPaths
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.findDuplicates(at: rootURL, mode: mode, ignoredPaths: ignored)
            }.value
            guard let self else { return }
            self.groups = result.groups
            self.scannedFiles = result.scannedFiles
            self.isScanning = false
            self.errorMessage = result.errorMessage
        }
    }

    func ignore(_ files: [DiskFile]) {
        ignoredPaths.formUnion(files.map(\.path))
        UserDefaults.standard.set(Array(ignoredPaths).sorted(), forKey: ignoredDefaultsKey)
        groups.removeAll { group in group.files.contains { ignoredPaths.contains($0.path) } }
    }

    func delete(_ files: [DiskFile]) {
        var failures: [String] = []
        for file in files {
            do { try FileManager.default.removeItem(at: file.url) }
            catch { failures.append(file.filename) }
        }
        if !failures.isEmpty {
            errorMessage = "以下文件未能删除：\(failures.joined(separator: "、"))"
        }
        scan()
    }

    private func restoreRoot() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        rootURL = url
        beginAccessingRoot(url)
        if stale { setRoot(url) }
    }

    private func beginAccessingRoot(_ url: URL) {
        if url.startAccessingSecurityScopedResource() {
            accessedRootURL = url
        }
    }

    private func stopAccessingRoot() {
        accessedRootURL?.stopAccessingSecurityScopedResource()
        accessedRootURL = nil
    }

    deinit {
        stopAccessingRoot()
    }

    nonisolated private static func findDuplicates(
        at root: URL,
        mode: MatchingMode,
        ignoredPaths: Set<String>
    ) -> (groups: [DuplicateGroup], scannedFiles: Int, errorMessage: String?) {
        let didAccess = root.startAccessingSecurityScopedResource()
        defer { if didAccess { root.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], 0, "无法读取该文件夹，请重新通过“选择文件夹”授权。")
        }

        var filesBySize: [Int64: [DiskFile]] = [:]
        var scanned = 0
        for case let url as URL in enumerator {
            guard !ignoredPaths.contains(url.path),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            scanned += 1
            // File-provider URLs often omit contentType; fall back to the
            // extension so images and movies still receive media previews.
            let contentType = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            let kind: DiskFile.FileKind
            if contentType?.conforms(to: .image) == true { kind = .image }
            else if contentType?.conforms(to: .movie) == true { kind = .video }
            else { kind = .file }
            filesBySize[Int64(size), default: []].append(DiskFile(url: url, size: Int64(size), type: kind))
        }

        let sameSize = filesBySize.values.filter { $0.count > 1 }
        if mode == .fileSize {
            return (sameSize.map { DuplicateGroup(key: "size-\($0[0].size)-\($0[0].path)", files: $0) }
                .sorted { $0.spaceToRecover > $1.spaceToRecover }, scanned, nil)
        }

        var byDigest: [String: [DiskFile]] = [:]
        for candidates in sameSize {
            for file in candidates {
                guard let digest = md5(of: file.url) else { continue }
                byDigest[digest, default: []].append(file)
            }
        }
        let groups = byDigest.compactMap { digest, files -> DuplicateGroup? in
            files.count > 1 ? DuplicateGroup(key: "md5-\(digest)", files: files) : nil
        }.sorted { $0.spaceToRecover > $1.spaceToRecover }
        return (groups, scanned, nil)
    }

    nonisolated private static func md5(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02hhx", $0) }.joined()
    }
}

enum FilePreview {
    static func thumbnail(for file: DiskFile) -> UIImage? {
        switch file.type {
        case .image: return UIImage(contentsOfFile: file.path)
        case .video: return videoThumbnail(url: file.url)
        case .file: return nil
        }
    }

    static func videoThumbnail(url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: image)
    }
}
