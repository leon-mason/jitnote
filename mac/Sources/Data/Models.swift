import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case github = "GITHUB"
    case gitee = "GITEE"
    case other = "OTHER"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .github: "GitHub"
        case .gitee: "Gitee"
        case .other: "其他 Git 服务"
        }
    }

    /// Whether the app can create repositories on this host through its API.
    var canCreateRepos: Bool { self != .other }
}

/// A connected cloud account. Its token lives in the Keychain, see `TokenVault`.
struct Account: Codable, Identifiable, Equatable {
    let id: String
    let provider: Provider
    /// Platform login; also the HTTPS user name.
    let login: String
    /// Email written into commits.
    let email: String
    let createdAt: Int64
}

struct Notebook: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    let accountId: String
    let remoteUrl: String
    /// Working copy directory name under the app's notebooks folder.
    let dir: String
    let createdAt: Int64
    var lastSyncAt: Int64?
    var lastSyncError: String?
}

enum NoteSort: String, Codable, CaseIterable, Identifiable {
    case modifiedDesc = "MODIFIED_DESC"
    case modifiedAsc = "MODIFIED_ASC"
    case titleAsc = "TITLE_ASC"
    case titleDesc = "TITLE_DESC"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .modifiedDesc: "修改时间（新的在前）"
        case .modifiedAsc: "修改时间（旧的在前）"
        case .titleAsc: "名称（A → Z）"
        case .titleDesc: "名称（Z → A）"
        }
    }
}

/// How a note opens: in the editor, or read-only.
enum ViewMode: String, Codable {
    case edit = "EDIT"
    case preview = "PREVIEW"
}

/// The app's own small state, kept as one JSON file (same fields as on Android, minus the token).
struct AppState: Codable, Equatable {
    var accounts: [Account] = []
    var notebooks: [Notebook] = []
    /// The notebook the main window shows; the first one when unset or removed.
    var currentNotebookId: String?
    var fileSort: NoteSort = .titleAsc
    /// Open folders of the file tree, per notebook id.
    var expandedFolders: [String: Set<String>] = [:]
    var defaultViewMode: ViewMode = .edit
    /// List files and folders starting with "." (never .git), see `NoteIndex.isHidden`.
    var showHiddenFiles = false
    /// Last successful check for a new app version, see `AppUpdates`.
    var lastUpdateCheckAt: Int64?

    var currentNotebook: Notebook? {
        notebooks.first { $0.id == currentNotebookId } ?? notebooks.first
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        notebooks = try c.decodeIfPresent([Notebook].self, forKey: .notebooks) ?? []
        currentNotebookId = try c.decodeIfPresent(String.self, forKey: .currentNotebookId)
        fileSort = (try? c.decodeIfPresent(NoteSort.self, forKey: .fileSort)) ?? .titleAsc
        expandedFolders = try c.decodeIfPresent([String: Set<String>].self, forKey: .expandedFolders) ?? [:]
        defaultViewMode = (try? c.decodeIfPresent(ViewMode.self, forKey: .defaultViewMode)) ?? .edit
        showHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        lastUpdateCheckAt = try c.decodeIfPresent(Int64.self, forKey: .lastUpdateCheckAt)
    }
}

func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
