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

/// A file that both this Mac and the cloud changed since the last sync.
/// The newer version was kept in the working tree; the other one is still in history
/// (`otherCommit`) and can be brought back with `NotebookGit.useOtherVersion`.
/// Stored in the same JSON shape as the Android app.
struct ConflictRecord: Codable, Equatable, Identifiable {
    let path: String
    let kept: Side
    /// Author time (ms) of the last change on the kept side.
    let keptTime: Int64
    let otherTime: Int64
    /// Blob of the version that was not kept; nil when that side deleted the file.
    let otherBlob: String?
    let otherCommit: String
    let createdAt: Int64

    var id: String { path }
}

struct SyncResult {
    /// Changes from the cloud were brought in.
    let pulled: Bool
    /// Local commits were uploaded.
    let pushed: Bool
    let conflicts: [ConflictRecord]
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
