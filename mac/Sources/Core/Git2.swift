import CGit2
import Foundation

/// A libgit2 failure with libgit2's own message.
struct GitError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { message }
}

/// Small helpers over the libgit2 C API. Only `NotebookGit` uses these.
enum Git2 {
    private static let setUp: Void = {
        git_libgit2_init()
        _ = gn_isolate_config()
        _ = gn_set_timeouts(60_000)
        _ = gn_use_system_certificates()
    }()

    /// Call once before any other libgit2 function.
    static func initialize() { _ = setUp }

    @discardableResult
    static func check(_ code: Int32) throws -> Int32 {
        guard code < 0 else { return code }
        let message = git_error_last().flatMap { $0.pointee.message.map { String(cString: $0) } } ?? "libgit2 error \(code)"
        throw GitError(code: code, message: message)
    }

    static func oid(_ string: String) throws -> git_oid {
        var oid = git_oid()
        try check(git_oid_fromstr(&oid, string))
        return oid
    }

    static func string(_ oid: git_oid) -> String {
        var copy = oid
        return String(cString: git_oid_tostr_s(&copy))
    }

    /// Runs [body] with a `git_strarray` holding [strings].
    static func withStrArray<T>(_ strings: [String], _ body: (inout git_strarray) throws -> T) rethrows -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            var array = git_strarray(strings: buffer.baseAddress, count: buffer.count)
            return try body(&array)
        }
    }
}

/// Credentials and progress for one network operation, handed to libgit2 callbacks as their payload.
final class TransferContext {
    let credentials: Credentials?
    let onProgress: ((Int, Int) -> Void)?
    var authAttempts = 0
    var pushRejections: [String] = []

    init(credentials: Credentials?, onProgress: ((Int, Int) -> Void)? = nil) {
        self.credentials = credentials
        self.onProgress = onProgress
    }

    func install(_ callbacks: inout git_remote_callbacks) {
        callbacks.payload = Unmanaged.passUnretained(self).toOpaque()
        callbacks.credentials = { out, _, _, allowed, payload in
            guard let payload else { return GIT_PASSTHROUGH.rawValue }
            let context = Unmanaged<TransferContext>.fromOpaque(payload).takeUnretainedValue()
            // Offer the token once; asking again would just repeat a rejected login.
            guard let credentials = context.credentials, context.authAttempts == 0,
                  allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0
            else { return GIT_EAUTH.rawValue }
            context.authAttempts += 1
            return git_credential_userpass_plaintext_new(out, credentials.username, credentials.password)
        }
        callbacks.transfer_progress = { stats, payload in
            guard let stats, let payload else { return 0 }
            let context = Unmanaged<TransferContext>.fromOpaque(payload).takeUnretainedValue()
            context.onProgress?(Int(stats.pointee.received_objects), Int(stats.pointee.total_objects))
            return 0
        }
        callbacks.push_update_reference = { _, status, payload in
            guard let status, let payload else { return 0 }
            let context = Unmanaged<TransferContext>.fromOpaque(payload).takeUnretainedValue()
            context.pushRejections.append(String(cString: status))
            return 0
        }
    }
}
