import Foundation

/// Who commits: written into every commit made on this Mac.
struct Author: Equatable {
    let name: String
    let email: String
}

/// HTTPS credentials. For GitHub / Gitee the password is the personal access token.
struct Credentials {
    let username: String
    let password: String
}

enum Side: String, Codable {
    case local = "LOCAL"
    case remote = "REMOTE"
}

/// A file that both this Mac and the cloud changed since the last sync, or that one side deleted
/// while the other changed it. Nothing is merged until the user says which side wins; the side that
/// loses stays in history, because the merge commit has both sides as parents.
struct PendingConflict: Identifiable, Equatable {
    let path: String
    /// Content on this Mac; nil when it was deleted here.
    let local: Data?
    /// Content in the cloud; nil when it was deleted there.
    let cloud: Data?

    var id: String { path }
}

struct SyncResult {
    /// Changes from the cloud were brought in.
    let pulled: Bool
    /// Local commits were uploaded.
    let pushed: Bool
    /// Files that were both changed and settled with the user's choices during this sync.
    let resolved: Int
    /// Conflicts that need a choice. When there are any, nothing was merged or uploaded: ask the user,
    /// then sync again with `choices`.
    let pending: [PendingConflict]
}

struct Version: Hashable, Identifiable {
    let commit: String
    let time: Int64
    let message: String
    let author: String

    var id: String { commit }
}

struct SyncError: Error, LocalizedError {
    enum Kind { case auth, network, notFound, rejected, other }

    let kind: Kind
    let message: String

    init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    var errorDescription: String? { message }
}
