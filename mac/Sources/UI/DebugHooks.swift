#if GN_DEBUG_HOOKS
import AppKit
import WebKit

/// Test-only remote control, compiled in by `scripts/build-mac.sh --debug`: lets automated checks
/// drive the window and photograph it, on machines that grant no screen-recording or accessibility
/// access. Commands arrive as distributed notifications named "Jitnote.debug":
///   snapshot <path-prefix>   every visible window → <prefix>-<n>.png
///   account <login> <password>   connects an "other" account (real code path, token in Keychain)
///   import <url>              downloads a notebook with the first account (real code path)
///   forget-accounts           disconnects every account, removing their Keychain tokens
///   settings                  opens the Settings window
///   js <expression>           evaluates in the editor and logs the result
///   dump <path>               writes the window's accessibility text tree (sidebar, toolbar, ...)
///   select <note path> | folder <path to highlight in the tree> | sync   handled by the main window
///   settings | tab <general|notebooks|accounts|about>   opens Settings / picks its tab
extension Notification.Name {
    static let debugCommand = Notification.Name("Jitnote.debugCommand")
}

enum DebugHooks {
    static func install() {
        DistributedNotificationCenter.default().addObserver(forName: .init("Jitnote.debug"), object: nil, queue: .main) { note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { run(command) }
        }
    }

    @MainActor
    private static func run(_ command: String) {
        let notebooks = AppModel.shared.notebooks
        let words = command.split(separator: " ").map(String.init)
        if command.hasPrefix("snapshot ") {
            snapshot(prefix: String(command.dropFirst("snapshot ".count)))
        } else if words.first == "account", words.count == 3 {
            Task { _ = try? await notebooks.addAccount(provider: .other, token: words[2], username: words[1], email: nil) }
        } else if words.first == "import", words.count == 2, let account = notebooks.state.accounts.first {
            Task {
                do {
                    let notebook = try await notebooks.importNotebook(url: words[1], account: account, name: "", onProgress: { _ in })
                    notebooks.setCurrent(notebook.id)
                } catch {
                    NSLog("import failed: \(error)")
                }
            }
        } else if words.first == "js" {
            let web = NSApp.windows.flatMap { $0.contentView.map(allSubviews) ?? [] }.compactMap { $0 as? WKWebView }.first
            NSLog("debug js: webView=\(web != nil) url=\(web?.url?.absoluteString ?? "-")")
            web?.evaluateJavaScript(String(command.dropFirst(3))) { result, error in
                NSLog("debug js result: \(String(describing: result)) error: \(String(describing: error))")
            }
        } else if words.first == "dump", words.count == 2 {
            var lines: [String] = []
            for window in NSApp.windows where window.isVisible { describe(window, depth: 0, into: &lines) }
            try? lines.joined(separator: "\n").write(toFile: words[1], atomically: true, encoding: .utf8)
        } else if command == "forget-accounts" {
            notebooks.state.accounts.forEach(notebooks.removeAccount)
        } else {
            NotificationCenter.default.post(name: .debugCommand, object: command)
        }
    }

    @MainActor
    private static func snapshot(prefix: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 50 }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
            let webViews = allSubviews(of: view).compactMap { $0 as? WKWebView }
            guard !webViews.isEmpty else {
                write(image, to: "\(prefix)-\(index).png")
                continue
            }
            // Web content is drawn out of process; take it separately and paint it in.
            var pending = webViews.count
            for web in webViews {
                web.takeSnapshot(with: nil) { picture, error in
                    if picture == nil { NSLog("debug snapshot of web view failed: \(String(describing: error))") }
                    if let picture {
                        let rect = web.convert(web.bounds, to: view)
                        image.lockFocus()
                        picture.draw(in: view.isFlipped ? NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect)
                        image.unlockFocus()
                    }
                    pending -= 1
                    if pending == 0 { write(image, to: "\(prefix)-\(index).png") }
                }
            }
        }
    }

    private static func describe(_ element: Any, depth: Int, into lines: inout [String]) {
        guard depth < 40, let element = element as? NSObject else { return }
        func attribute(_ name: NSAccessibility.Attribute) -> Any? { element.accessibilityAttributeValue(name) }
        let role = attribute(.role) as? String ?? "?"
        let text = [attribute(.title), attribute(.description), attribute(.value)]
            .compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " | ")
        if !text.isEmpty { lines.append(String(repeating: "  ", count: depth) + "\(role): \(text)") }
        for child in attribute(.children) as? [Any] ?? [] { describe(child, depth: depth + 1, into: &lines) }
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    private static func write(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
