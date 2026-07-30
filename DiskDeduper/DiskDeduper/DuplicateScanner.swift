import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import UIKit

enum ScanLimit: String, CaseIterable, Identifiable {
    case fiveHundred = "500 个"
    case oneThousand = "1,000 个"
    case fiveThousand = "5,000 个"
    case tenThousand = "10,000 个"
    case unlimited = "全部"

    var id: Self { self }
    var maximumHashes: Int {
        switch self {
        case .fiveHundred: return 500
        case .oneThousand: return 1_000
        case .fiveThousand: return 5_000
        case .tenThousand: return 10_000
        case .unlimited: return .max
        }
    }
}

struct ScanFeedback: Identifiable {
    let title: String
    let message: String
    let id = UUID()
}

private struct CachedDigest: Codable, Sendable {
    let size: Int64
    let modificationTime: TimeInterval
    let md5: String

    func matches(_ file: DiskFile) -> Bool {
        size == file.size && modificationTime == file.modificationTime
    }
}

private struct ScanResult: Sendable {
    let groups: [DuplicateGroup]
    let scannedFiles: Int
    let reusedHashes: Int
    let newlyHashed: Int
    let pendingHashes: Int
    let cache: [String: CachedDigest]
    let errorMessage: String?
}

private final class ScanCacheStore {
    private let directory: URL

    init() {
        directory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("DiskDeduper", isDirectory: true)
            .appendingPathComponent("ScanCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load(for root: URL) -> [String: CachedDigest] {
        guard let data = try? Data(contentsOf: fileURL(for: root)) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedDigest].self, from: data)) ?? [:]
    }

    func save(_ cache: [String: CachedDigest], for root: URL) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL(for: root), options: .atomic)
    }

    private func fileURL(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.absoluteString.utf8))
            .map { String(format: "%02hhx", $0) }
            .joined()
        return directory.appendingPathComponent("\(digest).json")
    }
}

struct DiskFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let type: FileKind
    let cacheKey: String
    let modificationTime: TimeInterval

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
    @Published var scanLimit: ScanLimit = .fiveThousand {
        didSet { UserDefaults.standard.set(scanLimit.rawValue, forKey: scanLimitDefaultsKey) }
    }
    @Published var isScanning = false
    @Published var scannedFiles = 0
    @Published var reusedHashes = 0
    @Published var newlyHashed = 0
    @Published var pendingHashes = 0
    @Published var errorMessage: String?
    @Published var feedback: ScanFeedback?

    private let ignoredDefaultsKey = "DiskDeduper.ignoredPaths"
    private let bookmarkDefaultsKey = "DiskDeduper.rootBookmark"
    private let scanLimitDefaultsKey = "DiskDeduper.scanLimit"
    private let deletionPriorityDefaultsKey = "DiskDeduper.deletionPriorityDirectories"
    private var ignoredPaths: Set<String> = []
    private var deletionPriorityDirectories: Set<String> = []
    private var accessedRootURL: URL?
    private let cacheStore = ScanCacheStore()
    private var currentCache: [String: CachedDigest] = [:]

    init() {
        ignoredPaths = Set(UserDefaults.standard.stringArray(forKey: ignoredDefaultsKey) ?? [])
        if let rawValue = UserDefaults.standard.string(forKey: scanLimitDefaultsKey),
           let persistedLimit = ScanLimit(rawValue: rawValue) {
            scanLimit = persistedLimit
        }
        restoreRoot()
    }

    var totalDuplicates: Int { groups.reduce(0) { $0 + max(0, $1.files.count - 1) } }
    var recoverableSpace: Int64 { groups.reduce(0) { $0 + $1.spaceToRecover } }
    let matchingDescription = "按文件大小粗筛，再以 MD5 内容确认重复。"

    func setRoot(_ url: URL) {
        stopAccessingRoot()
        rootURL = url
        beginAccessingRoot(url)
        loadDeletionPriorityDirectories(for: url)
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
        reusedHashes = 0
        newlyHashed = 0
        pendingHashes = 0
        let ignored = ignoredPaths
        let cachedDigests = cacheStore.load(for: rootURL)
        currentCache = cachedDigests
        let limit = scanLimit.maximumHashes
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.findDuplicates(
                    at: rootURL,
                    ignoredPaths: ignored,
                    cachedDigests: cachedDigests,
                    maximumNewHashes: limit
                )
            }.value
            guard let self else { return }
            self.groups = result.groups
            self.scannedFiles = result.scannedFiles
            self.reusedHashes = result.reusedHashes
            self.newlyHashed = result.newlyHashed
            self.pendingHashes = result.pendingHashes
            self.currentCache = result.cache
            self.cacheStore.save(result.cache, for: rootURL)
            self.isScanning = false
            self.errorMessage = result.errorMessage
        }
    }

    func ignore(_ files: [DiskFile]) {
        ignoredPaths.formUnion(files.map(\.cacheKey))
        UserDefaults.standard.set(Array(ignoredPaths).sorted(), forKey: ignoredDefaultsKey)
        groups = groups.compactMap { group in
            let remaining = group.files.filter { !ignoredPaths.contains($0.cacheKey) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(key: group.key, files: remaining)
        }
    }

    func delete(_ files: [DiskFile]) {
        var failures: [String] = []
        var deletedKeys: Set<String> = []
        for file in files {
            do {
                try FileManager.default.removeItem(at: file.url)
                deletedKeys.insert(file.cacheKey)
            }
            catch { failures.append(file.filename) }
        }
        guard !deletedKeys.isEmpty || !failures.isEmpty else { return }

        // Do not rescan the drive after each deletion. Remove only the deleted
        // files from the in-memory result and cache; the next explicit scan
        // will reconcile metadata changes across the whole selected folder.
        if !deletedKeys.isEmpty {
            deletionPriorityDirectories.formUnion(
                files
                    .filter { deletedKeys.contains($0.cacheKey) }
                    .map { directoryKey(for: $0) }
            )
            if let rootURL { saveDeletionPriorityDirectories(for: rootURL) }
            groups = groups.compactMap { group in
                let remaining = group.files.filter { !deletedKeys.contains($0.cacheKey) }
                guard remaining.count > 1 else { return nil }
                return DuplicateGroup(key: group.key, files: remaining)
            }
            currentCache = currentCache.filter { !deletedKeys.contains($0.key) }
            if let rootURL { cacheStore.save(currentCache, for: rootURL) }
        }

        if failures.isEmpty {
            feedback = ScanFeedback(title: "删除完成", message: "已删除 \(deletedKeys.count) 个重复文件，当前结果已直接更新。")
        } else {
            feedback = ScanFeedback(
                title: "删除部分完成",
                message: "已删除 \(deletedKeys.count) 个文件；未能删除：\(failures.joined(separator: "、"))。"
            )
        }
    }

    func duplicateFiles(in groupIDs: Set<String>) -> [DiskFile] {
        groups
            .filter { groupIDs.contains($0.id) }
            .flatMap { preferredDuplicatesToDelete(in: $0) }
    }

    func preferredDuplicatesToDelete(in group: DuplicateGroup) -> [DiskFile] {
        guard group.files.count > 1 else { return [] }
        let preferredKeepers = group.files.filter {
            !deletionPriorityDirectories.contains(directoryKey(for: $0))
        }
        let keeper = (preferredKeepers.isEmpty ? group.files : preferredKeepers)
            .min { $0.cacheKey.localizedStandardCompare($1.cacheKey) == .orderedAscending }
        guard let keeper else { return [] }
        return group.files.filter { $0.id != keeper.id }
    }

    private func restoreRoot() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        rootURL = url
        beginAccessingRoot(url)
        loadDeletionPriorityDirectories(for: url)
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

    private func directoryKey(for file: DiskFile) -> String {
        let directory = (file.cacheKey as NSString).deletingLastPathComponent
        return directory == "." ? "" : directory
    }

    private func loadDeletionPriorityDirectories(for root: URL) {
        let allDirectories = UserDefaults.standard.dictionary(forKey: deletionPriorityDefaultsKey) as? [String: [String]] ?? [:]
        deletionPriorityDirectories = Set(allDirectories[rootIdentifier(for: root)] ?? [])
    }

    private func saveDeletionPriorityDirectories(for root: URL) {
        var allDirectories = UserDefaults.standard.dictionary(forKey: deletionPriorityDefaultsKey) as? [String: [String]] ?? [:]
        allDirectories[rootIdentifier(for: root)] = Array(deletionPriorityDirectories).sorted()
        UserDefaults.standard.set(allDirectories, forKey: deletionPriorityDefaultsKey)
    }

    private func rootIdentifier(for root: URL) -> String {
        SHA256.hash(data: Data(root.absoluteString.utf8))
            .map { String(format: "%02hhx", $0) }
            .joined()
    }

    nonisolated private static func findDuplicates(
        at root: URL,
        ignoredPaths: Set<String>,
        cachedDigests: [String: CachedDigest],
        maximumNewHashes: Int
    ) -> ScanResult {
        let didAccess = root.startAccessingSecurityScopedResource()
        defer { if didAccess { root.stopAccessingSecurityScopedResource() } }
        // A removable drive can contain hundreds of thousands of files.  Do not
        // retain every URL just to discover that most sizes are unique: count
        // sizes first, then materialize metadata only for same-size candidates.
        let countingKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let countingEnumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(countingKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ScanResult(groups: [], scannedFiles: 0, reusedHashes: 0, newlyHashed: 0, pendingHashes: 0, cache: [:], errorMessage: "无法读取该文件夹，请重新通过“选择文件夹”授权。")
        }

        var sizeCounts: [Int64: Int] = [:]
        var scanned = 0
        for case let url as URL in countingEnumerator {
            autoreleasepool {
                let cacheKey = relativePath(of: url, from: root)
                guard !ignoredPaths.contains(cacheKey),
                      let values = try? url.resourceValues(forKeys: countingKeys),
                      values.isRegularFile == true,
                      let size = values.fileSize else { return }
                scanned += 1
                sizeCounts[Int64(size), default: 0] += 1
            }
        }

        let candidateSizes = Set(sizeCounts.compactMap { size, count in count > 1 ? size : nil })
        guard !candidateSizes.isEmpty else {
            return ScanResult(groups: [], scannedFiles: scanned, reusedHashes: 0, newlyHashed: 0, pendingHashes: 0, cache: [:], errorMessage: nil)
        }

        let detailKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey]
        guard let detailEnumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(detailKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ScanResult(groups: [], scannedFiles: scanned, reusedHashes: 0, newlyHashed: 0, pendingHashes: 0, cache: [:], errorMessage: "无法再次读取该文件夹，请重新通过“选择文件夹”授权。")
        }

        var filesBySize: [Int64: [DiskFile]] = [:]
        for case let url as URL in detailEnumerator {
            autoreleasepool {
                let cacheKey = relativePath(of: url, from: root)
                guard !ignoredPaths.contains(cacheKey),
                      let values = try? url.resourceValues(forKeys: detailKeys),
                      values.isRegularFile == true,
                      let fileSize = values.fileSize else { return }
                let size = Int64(fileSize)
                guard candidateSizes.contains(size) else { return }

                // File-provider URLs often omit contentType; fall back to the
                // extension so images and movies still receive media previews.
                let contentType = values.contentType ?? UTType(filenameExtension: url.pathExtension)
                let kind: DiskFile.FileKind
                if contentType?.conforms(to: .image) == true { kind = .image }
                else if contentType?.conforms(to: .movie) == true { kind = .video }
                else { kind = .file }
                let modificationTime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                filesBySize[size, default: []].append(
                    DiskFile(url: url, size: size, type: kind, cacheKey: cacheKey, modificationTime: modificationTime)
                )
            }
        }

        var byDigest: [String: [DiskFile]] = [:]
        var nextCache: [String: CachedDigest] = [:]
        var filesToHash: [DiskFile] = []
        var pendingHashCount = 0
        var reused = 0
        for candidates in filesBySize.values {
            for file in candidates {
                if let cached = cachedDigests[file.cacheKey], cached.matches(file) {
                    byDigest[cached.md5, default: []].append(file)
                    nextCache[file.cacheKey] = cached
                    reused += 1
                } else if filesToHash.count < maximumNewHashes {
                    filesToHash.append(file)
                } else {
                    pendingHashCount += 1
                }
            }
        }
        for file in filesToHash {
            guard let digest = md5(of: file.url) else { continue }
            byDigest[digest, default: []].append(file)
            nextCache[file.cacheKey] = CachedDigest(size: file.size, modificationTime: file.modificationTime, md5: digest)
        }
        let groups = byDigest.compactMap { digest, files -> DuplicateGroup? in
            files.count > 1 ? DuplicateGroup(key: "md5-\(digest)", files: files) : nil
        }.sorted { $0.spaceToRecover > $1.spaceToRecover }
        return ScanResult(
            groups: groups,
            scannedFiles: scanned,
            reusedHashes: reused,
            newlyHashed: filesToHash.count,
            pendingHashes: pendingHashCount,
            cache: nextCache,
            errorMessage: nil
        )
    }

    nonisolated private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
