import CoreServices
import Foundation

/// Reports changes inside a notebook folder as they happen, whoever makes them: an AI, a terminal,
/// Finder, another editor, or this app itself. Paths are relative to the folder. Everything under `.git`
/// is left out: Git's own bookkeeping would fire on every sync, and what matters there (unsynced
/// work) is checked when the window comes forward.
///
/// Call `stop()` when done. The stream holds a strong reference to the watcher until then, so a
/// callback already on its way can never reach a watcher that is gone.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let rootPath: String
    private let onChange: ([String]) -> Void

    /// [latency] is how long events are gathered into one report (FSEvents already merges bursts, such as a
    /// sync writing many files); [queue] is where [onChange] runs.
    init?(folder: URL, latency: TimeInterval = 0.3, queue: DispatchQueue = .main, onChange: @escaping ([String]) -> Void) {
        // FSEvents reports real paths (/private/var/...). URL.resolvingSymlinksInPath() would turn that back
        // into /var/..., so ask the C library for the real path instead.
        rootPath = realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? folder.path
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                _ = Unmanaged<FolderWatcher>.fromOpaque(info!).retain()
                return info
            },
            release: { info in Unmanaged<FolderWatcher>.fromOpaque(info!).release() },
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue()
            watcher.deliver((unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? [])
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [rootPath] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func deliver(_ absolute: [String]) {
        var seen = Set<String>()
        var relative: [String] = []
        for path in absolute {
            guard path.hasPrefix(rootPath + "/") else { continue }
            let inside = String(path.dropFirst(rootPath.count + 1))
            if inside == ".git" || inside.hasPrefix(".git/") { continue }
            // An atomic write (this app saving a note) first makes "name.sb-xxxxxxxx-xxxxxx" and renames it over
            // the file; the real name is reported as well, so the temporary one is only noise.
            if inside.range(of: #"\.sb-[0-9a-f]{8}-[A-Za-z0-9]+$"#, options: .regularExpression) != nil { continue }
            if seen.insert(inside).inserted { relative.append(inside) }
        }
        if !relative.isEmpty { onChange(relative) }
    }
}
