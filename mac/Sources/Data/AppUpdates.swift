import Foundation

/// Finds a newer published release of this app on GitHub and downloads its Mac build.
/// Talks to GitHub anonymously: no token and nothing about the user's notes is sent.
@MainActor
final class AppUpdates: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        let downloadUrl: URL
        let size: Int64

        /// A DMG opens to the familiar drag-to-Applications window; older releases only have a ZIP.
        var isDiskImage: Bool { downloadUrl.pathExtension.lowercased() == "dmg" }
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

    static let repo = "leon-mason/jitnote"
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
                // Offline or GitHub unreachable: try again next launch, without bothering anyone.
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
                state = .failed("连不上 GitHub，请检查网络后再试。", release: nil)
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

    /// The newest public release if it is newer than this app, else nil.
    private func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!, timeoutInterval: 30)
        request.setValue("Jitnote-Mac", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // No release published yet.
        if code == 404 { return nil }
        guard (200..<300).contains(code), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return Self.parseRelease(json).flatMap { Self.isNewer($0.version, than: currentVersion) ? $0 : nil }
    }

    private func fetch(_ release: Release) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Jitnote-update-\(release.version)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let download = dir.appendingPathComponent(release.downloadUrl.lastPathComponent)

        let (bytes, response) = try await URLSession.shared.bytes(from: release.downloadUrl)
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw URLError(.badServerResponse) }
        FileManager.default.createFile(atPath: download.path, contents: nil)
        let handle = try FileHandle(forWritingTo: download)
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
                    state = .downloading(release, downloaded: total)
                }
            }
        }
        try handle.write(contentsOf: buffer)
        total += Int64(buffer.count)
        try handle.close()
        if release.size > 0 && total != release.size { throw URLError(.networkConnectionLost) }
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

    /// The chip in Mac package names: Jitnote-mac-apple-silicon-0.4.0.dmg (an Intel build would say "intel").
    nonisolated static var chip: String {
        #if arch(arm64)
        "apple-silicon"
        #else
        "intel"
        #endif
    }

    /// Reads a GitHub release: the Mac package for [chip], DMG before ZIP. Packages named for another chip
    /// are skipped; ones with no chip in the name (0.3.0) are taken as a last resort. Nil when there is no
    /// Mac build or the release is a draft or pre-release.
    nonisolated static func parseRelease(_ release: [String: Any], chip: String = chip) -> Release? {
        if release["draft"] as? Bool == true || release["prerelease"] as? Bool == true { return nil }
        guard var version = release["tag_name"] as? String else { return nil }
        if version.hasPrefix("v") { version.removeFirst() }
        let assets = release["assets"] as? [[String: Any]] ?? []
        let chips = ["apple-silicon", "intel"]
        func macAsset(_ suffix: String, chip wanted: String?) -> [String: Any]? {
            assets.first { asset in
                guard let name = asset["name"] as? String, name.contains("-mac"), name.hasSuffix(suffix) else { return false }
                let named = chips.first { name.contains("-\($0)") }
                return named == wanted
            }
        }
        guard let asset = macAsset(".dmg", chip: chip) ?? macAsset(".zip", chip: chip)
                ?? macAsset(".dmg", chip: nil) ?? macAsset(".zip", chip: nil),
              let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let notes = (release["body"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Release(version: version, notes: notes, downloadUrl: url, size: (asset["size"] as? NSNumber)?.int64Value ?? 0)
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
