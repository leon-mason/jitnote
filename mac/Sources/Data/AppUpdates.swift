import CryptoKit
import Foundation

/// Finds a newer version of this app from the latest.json that each release carries on GitHub and on Gitee,
/// and downloads its Mac build. Both requests are anonymous: no token, no device identifier, nothing about the
/// user's notes. Installing is left to the user (the UI opens the DMG).
@MainActor
final class AppUpdates: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        /// Tried in order: Gitee first, GitHub as the fallback (design.md「检查更新」).
        let downloadUrls: [URL]
        let size: Int64
        let sha256: String

        /// A DMG opens to the familiar drag-to-Applications window. Releases only list DMGs now; the ZIP
        /// branch stays so a package that is not one still installs.
        var isDiskImage: Bool { downloadUrls.first?.pathExtension.lowercased() == "dmg" }
    }

    enum State: Equatable {
        case idle
        /// Only for a check the user started; the check on launch stays silent.
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, downloaded: Int64)
        /// The new version, ready to install: the DMG, or the app unpacked from a ZIP.
        case downloaded(Release, file: URL)
        /// `release` is set when the download failed, so it can be retried.
        case failed(String, release: Release?)
    }

    nonisolated static let repo = "leon-mason/jitnote"
    private static let checkInterval: Int64 = 24 * 60 * 60 * 1000

    let currentVersion: String
    private let store: StateStore
    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    init(store: StateStore, currentVersion: String) {
        self.store = store
        self.currentVersion = currentVersion
    }

    /// Checks at most once a day and says nothing unless there is a new version.
    func checkOnLaunch() {
        let last = store.state.lastUpdateCheckAt ?? 0
        guard nowMillis() - last >= Self.checkInterval, task == nil else { return }
        task = Task {
            defer { task = nil }
            do {
                let release = try await latestRelease()
                store.update { $0.lastUpdateCheckAt = nowMillis() }
                if let release, state == .idle { state = .available(release) }
            } catch {
                // Offline, or neither site answered: try again next launch, without bothering anyone.
            }
        }
    }

    func checkNow() {
        task?.cancel()
        state = .checking
        task = Task {
            defer { task = nil }
            do {
                let release = try await latestRelease()
                store.update { $0.lastUpdateCheckAt = nowMillis() }
                state = release.map { .available($0) } ?? .upToDate
            } catch is CancellationError {
            } catch {
                state = .failed("检查更新没有成功，请检查网络后再试。", release: nil)
            }
        }
    }

    func download(_ release: Release) {
        task?.cancel()
        state = .downloading(release, downloaded: 0)
        task = Task {
            defer { task = nil }
            do {
                let file = try await fetch(release)
                state = .downloaded(release, file: file)
            } catch is CancellationError {
            } catch {
                state = .failed("下载没有完成，可能是网络不稳定。", release: release)
            }
        }
    }

    /// Closes whatever is showing; also stops a check or download in progress.
    func dismiss() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// The newest version if it is newer than this app, else nil. Asks GitHub and Gitee at once and takes
    /// whichever answers first, so users who cannot reach GitHub do not wait for it to time out. The slower
    /// request is left to finish: each download of latest.json on GitHub is what estimates daily users
    /// (design.md「检查更新」).
    private func latestRelease() async throws -> Release? {
        let key = "mac-\(Self.chip)"
        let release = try await Self.firstSuccess(Self.manifestUrls.map { url in
            { try Self.parseManifest(try await Self.fetchData(url), package: key) }
        })
        // The race itself does not stop when this check is cancelled (it must not cancel the requests).
        try Task.checkCancellation()
        return release.flatMap { Self.isNewer($0.version, than: currentVersion) ? $0 : nil }
    }

    private func fetch(_ release: Release) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Jitnote-update-\(release.version)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let first = release.downloadUrls.first else { throw URLError(.badURL) }
        let download = dir.appendingPathComponent(first.lastPathComponent)
        try await Self.downloadVerified(release.downloadUrls, to: download, size: release.size, sha256: release.sha256) { url, file in
            self.state = .downloading(release, downloaded: 0)
            try await self.fetchFile(url, to: file) { self.state = .downloading(release, downloaded: $0) }
        }
        if release.isDiskImage { return download }

        // ditto keeps the app bundle's structure and signature intact.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", download.path, dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
        else { throw URLError(.cannotDecodeContentData) }
        return app
    }

    private func fetchFile(_ url: URL, to file: URL, progress: (Int64) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw URLError(.badServerResponse) }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        var total: Int64 = 0
        var lastShown: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                total += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total - lastShown >= 256 * 1024 {
                    lastShown = total
                    progress(total)
                }
            }
        }
        try handle.write(contentsOf: buffer)
    }

    private nonisolated static let userAgent = "Jitnote-Mac"

    /// Fixed addresses of the newest release's latest.json. scripts/release.sh uploads it last, after every
    /// package is on both sites. Gitee has no draft releases and counts the release edited last as the
    /// newest, which is why the release script never edits an older one.
    nonisolated static let manifestUrls = [
        URL(string: "https://gitee.com/shitoupapa/jitnote/releases/download/latest/latest.json")!,
        URL(string: "https://github.com/\(repo)/releases/latest/download/latest.json")!,
    ]

    private nonisolated static func fetchData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Never answer from the local cache: GitHub only counts a download when github.com is asked.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Reads latest.json as written by scripts/release.sh. Throws when the file is unreadable, so the other
    /// site's answer can be used instead; nil when it lists no usable package under `package`.
    nonisolated static func parseManifest(_ data: Data, package key: String) throws -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var version = json["version"] as? String
        else { throw URLError(.cannotParseResponse) }
        if version.hasPrefix("v") { version.removeFirst() }
        guard let package = (json["packages"] as? [String: Any])?[key] as? [String: Any],
              let size = (package["size"] as? NSNumber)?.int64Value,
              let sha256 = (package["sha256"] as? String)?.lowercased(),
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit })
        else { return nil }
        let urls = [package["gitee"], package["github"]]
            .compactMap { ($0 as? String).flatMap(URL.init(string:)) }
            .filter { $0.scheme == "https" }
        if urls.isEmpty { return nil }
        let notes = (json["notes"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Release(version: version, notes: notes, downloadUrls: urls, size: size, sha256: sha256)
    }

    /// Runs every attempt in its own task and returns the first result; throws only when all of them failed.
    /// The others are not cancelled, even when the caller is.
    nonisolated static func firstSuccess<T>(_ attempts: [@Sendable () async throws -> T]) async throws -> T {
        guard !attempts.isEmpty else { throw URLError(.badURL) }
        let race = Race<T>(count: attempts.count)
        return try await withCheckedThrowingContinuation { continuation in
            race.start(continuation)
            for attempt in attempts {
                Task.detached {
                    do { race.succeed(try await attempt()) } catch { race.fail(error) }
                }
            }
        }
    }

    private final class Race<T>: @unchecked Sendable {
        private let lock = NSLock()
        private let count: Int
        private var failures = 0
        private var continuation: CheckedContinuation<T, Error>?

        init(count: Int) { self.count = count }

        func start(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock(); defer { lock.unlock() }
            self.continuation = continuation
        }

        func succeed(_ value: T) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: value)
        }

        func fail(_ error: Error) {
            lock.lock()
            failures += 1
            let waiting = failures == count ? continuation : nil
            if waiting != nil { continuation = nil }
            lock.unlock()
            waiting?.resume(throwing: error)
        }
    }

    /// Downloads into `file` from each URL in turn until one gives exactly `size` bytes with the expected
    /// SHA-256. A package that does not match is never kept, so it can never be installed.
    nonisolated static func downloadVerified(
        _ urls: [URL], to file: URL, size: Int64, sha256: String,
        fetch: (URL, URL) async throws -> Void
    ) async throws {
        var last: Error = URLError(.badURL)
        for url in urls {
            do {
                try await fetch(url, file)
                let actual = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
                if actual == size, try sha256Of(file) == sha256 { return }
                last = URLError(.cannotDecodeContentData)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: file)
                throw CancellationError()
            } catch {
                last = error
            }
            try? FileManager.default.removeItem(at: file)
        }
        throw last
    }

    nonisolated static func sha256Of(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The chip in Mac package names: Jitnote-mac-apple-silicon-0.4.0.dmg (an Intel build would say "intel").
    nonisolated static var chip: String {
        #if arch(arm64)
        "apple-silicon"
        #else
        "intel"
        #endif
    }

    /// Compares dotted version numbers, ignoring a leading "v"; unreadable versions are never newer.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let diff = (i < a.count ? a[i] : 0) - (i < b.count ? b[i] : 0)
            if diff != 0 { return diff > 0 }
        }
        return false
    }

    private nonisolated static func parts(_ version: String) -> [Int]? {
        var text = version
        if text.hasPrefix("v") { text.removeFirst() }
        let numbers = (text.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) }
        return numbers.contains(nil) || numbers.isEmpty ? nil : numbers.map { $0! }
    }
}
