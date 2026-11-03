import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Lets the window save the open note before syncing or when the app goes to the background.
@MainActor
final class EditorBridge: ObservableObject {
    fileprivate weak var controller: EditorController?
    fileprivate var plainText: (() -> Void)?
    fileprivate var plainReload: (() async -> Void)?

    /// Writes the open note's latest content to disk.
    func flush() async {
        plainText?()
        await controller?.flush()
    }

    /// Shows what another program wrote into the open note, if it did. The file is the only truth, so
    /// the editor follows it, without asking.
    func reloadFromDisk() async {
        await controller?.reloadFromDisk()
        await plainReload?()
    }
}

private let scheme = "jitnote"
private let host = "app"

/// The editor's web view. WebKit offers a key equivalent to the page before the menu, and the editor
/// binds ⌘E to inline code, so the shortcut for switching edit/preview would never reach the menu
/// while the cursor is in the text. Handle it here, ahead of the page.
private final class EditorWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "e" {
            NotificationCenter.default.post(name: .toggleViewMode, object: nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The shared web editor (see /editor in the repository) showing one note in a WKWebView.
/// Same host interface as Android: JitnoteHost.onReady / onChange / resolveFile / openImage.
@MainActor
final class EditorController: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, WKURLSchemeHandler {
    /// Created after `init` registers this object as the scheme handler: WebKit copies the configuration.
    private(set) var webView: WKWebView!
    private let root: URL
    private let path: String
    private let folder: String
    private var content: String
    /// Preview shows the note read-only. Changes while the note is open, so `ready` reads the latest value.
    private(set) var readonly: Bool
    private let saver: NoteSaver
    private let assets: NoteAssets
    var onOpenImage: (String) -> Void = { _ in }
    var onSaved: () -> Void = {}

    init(root: URL, path: String, content: String, readonly: Bool) {
        self.root = root
        self.path = path
        folder = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
        self.content = content
        self.readonly = readonly
        saver = NoteSaver(file: root.appendingPathComponent(path), loaded: content)
        assets = NoteAssets(root: root)
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(self, forURLScheme: scheme)
        let shim = """
        window.JitnoteHost = {
          onReady: () => window.webkit.messageHandlers.host.postMessage({ type: 'ready' }),
          onChange: (markdown) => window.webkit.messageHandlers.host.postMessage({ type: 'change', markdown }),
          openImage: (path) => window.webkit.messageHandlers.host.postMessage({ type: 'openImage', path }),
          // The editor needs the answer right away; prompt() is WebKit's only synchronous way to ask the app.
          resolveFile: (path) => window.prompt('jitnote:resolveFile', path) || '',
        };
        """
        configuration.userContentController.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(self, name: "host")
        webView = EditorWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: URL(string: "\(scheme)://\(host)/editor/index.html")!))
    }

    /// Switches between editing and read-only preview without reloading. Before the editor has loaded
    /// the call is a no-op; `ready` passes the current value then.
    func setReadonly(_ readonly: Bool) {
        guard readonly != self.readonly else { return }
        self.readonly = readonly
        webView.evaluateJavaScript("window.JitnoteEditor && window.JitnoteEditor.setReadonly(\(readonly))")
    }

    /// Saves the latest content; called before syncing, when switching notes and when the app goes away.
    func flush() async {
        let markdown = try? await webView.evaluateJavaScript("window.JitnoteEditor ? window.JitnoteEditor.getMarkdown() : null") as? String
        if saver.save(markdown) { onSaved() }
    }

    /// Brings the editor in line with the file after another program changed it. This app's own saves
    /// are told apart by content (the file then holds exactly what was last saved), so they change nothing.
    func reloadFromDisk() async {
        let file = root.appendingPathComponent(path)
        // A note that is gone is left alone: the window shows its own state for that, and nothing is written back.
        guard let disk = await Task.detached(operation: { try? String(contentsOf: file, encoding: .utf8) }).value,
              saver.changedOnDisk(disk) else { return }
        saver.adopt(disk)
        content = disk
        // The editor drops a report it was about to send for the old text (editor/src/main.js, load).
        _ = try? await webView.evaluateJavaScript("window.JitnoteEditor && window.JitnoteEditor.load(\(Self.json(disk)), \(optionsJson()))")
    }

    func close() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "host")
    }

    private func optionsJson() -> String {
        let options: [String: Any] = [
            "readonly": readonly,
            "baseUrl": notebookUrl(folder.isEmpty ? "" : folder + "/"),
            "notebookUrl": notebookUrl(""),
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: options), encoding: .utf8)!
    }

    /// [text] as a JSON string literal, ready to put in a script.
    private static func json(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast().description
    }

    // MARK: Messages from the editor

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            webView.evaluateJavaScript("window.JitnoteEditor.load(\(Self.json(content)), \(optionsJson()))")
        case "change":
            saver.markEdited()
            if saver.save(body["markdown"] as? String) { onSaved() }
        case "openImage":
            // Only open what resolveFile handed out, i.e. a file inside this notebook.
            if let path = body["path"] as? String, assets.resolve(noteFolder: "", reference: path) == path { onOpenImage(path) }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard prompt == "jitnote:resolveFile", let reference = defaultText else { return completionHandler(nil) }
        completionHandler(assets.resolve(noteFolder: folder, reference: reference) ?? "")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Links inside notes open in the browser, never inside the editor.
        if action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // MARK: Files for the editor: its own page, and images from the notebook

    private func notebookUrl(_ path: String) -> String {
        "\(scheme)://\(host)/notebook/" + path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = localFile(for: url), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: task.request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": mime, "Content-Length": "\(data.count)",
        ])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func localFile(for url: URL) -> URL? {
        let path = url.path.removingPercentEncoding ?? url.path
        if path.hasPrefix("/editor/"), let resources = Bundle.main.resourceURL?.appendingPathComponent("editor") {
            return inside(resources, String(path.dropFirst("/editor/".count)))
        }
        if path.hasPrefix("/notebook/") {
            let relative = String(path.dropFirst("/notebook/".count))
            guard relative != ".git", !relative.hasPrefix(".git/") else { return nil }
            return inside(root, relative)
        }
        return nil
    }

    /// [relative] under [base], or nil if it would leave [base].
    private func inside(_ base: URL, _ relative: String) -> URL? {
        let resolved = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.path.hasPrefix(basePath + "/") ? resolved : nil
    }
}

/// A note in the shared rich editor.
struct RichEditor: NSViewRepresentable {
    let root: URL
    let path: String
    let content: String
    let readonly: Bool
    let bridge: EditorBridge
    let onSaved: () -> Void
    let onOpenImage: (String) -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var controller: EditorController?
        var onClose: (() -> Void)?
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = EditorController(root: root, path: path, content: content, readonly: readonly)
        controller.onSaved = onSaved
        controller.onOpenImage = onOpenImage
        context.coordinator.controller = controller
        context.coordinator.onClose = onClose
        bridge.controller = controller
        return controller.webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.controller?.setReadonly(readonly)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        guard let controller = coordinator.controller else { return }
        // Leaving the note counts as "done editing": save the last edits, then record a version.
        Task { @MainActor in
            await controller.flush()
            controller.close()
            coordinator.onClose?()
        }
    }
}

/// Text files that are not Markdown (.txt) are edited as plain text.
struct PlainEditor: View {
    let file: URL
    let initial: String
    let bridge: EditorBridge
    let onSaved: () -> Void
    let onClose: () -> Void

    @State private var text = ""
    /// What the file held when it was last read; `text` differing from it is what counts as an edit.
    @State private var loaded = ""
    @State private var saver: NoteSaver?

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
            .onAppear {
                text = initial
                loaded = initial
                saver = NoteSaver(file: file, loaded: initial)
                bridge.plainText = { save() }
                bridge.plainReload = { await reload() }
            }
            .onChange(of: text) { _, value in
                if value != loaded { saver?.markEdited() }
            }
            .task(id: text) {
                try? await Task.sleep(for: .milliseconds(800))
                save()
            }
            .onDisappear {
                save()
                bridge.plainText = nil
                bridge.plainReload = nil
                onClose()
            }
    }

    private func save() {
        if saver?.save(text) == true { onSaved() }
    }

    /// Follows the file after another program changed it (see `EditorBridge.reloadFromDisk`).
    private func reload() async {
        let file = file
        guard let disk = await Task.detached(operation: { try? String(contentsOf: file, encoding: .utf8) }).value,
              saver?.changedOnDisk(disk) == true else { return }
        saver?.adopt(disk)
        loaded = disk
        text = disk
    }
}

/// A picture from the notebook, full size, with zoom (pinch, or the toolbar buttons).
struct ImageViewer: View {
    let file: URL
    let onClose: () -> Void
    @State private var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button { scale = max(0.25, scale / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { scale = 1 } label: { Text("\(Int(scale * 100))%").monospacedDigit() }
                Button { scale = min(8, scale * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                Button("完成", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                if let image = NSImage(contentsOf: file) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .gesture(MagnificationGesture().onChanged { scale = min(8, max(0.25, $0)) })
                } else {
                    Text("这张图片打不开").foregroundStyle(.secondary).padding(40)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// Any other file (Word, Excel, PowerPoint, PDF, Keynote, video…) shown read-only by Quick Look,
/// the same preview Finder gives on the space bar. Types it doesn't know show their icon and size.
struct FilePreview: NSViewRepresentable {
    let file: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = file as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != file { view.previewItem = file as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
