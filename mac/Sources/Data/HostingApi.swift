import Foundation

/// The few platform REST calls the app needs: who owns this token, create a private repository,
/// and list the account's repositories. Notes themselves never go through these APIs, only through Git.
enum HostingApi {
    struct User {
        let login: String
        let email: String
    }

    struct CreatedRepo {
        let cloneUrl: String
        let webUrl: String
    }

    /// A repository the account can access, as shown when choosing one to turn into a notebook.
    struct RemoteRepo: Identifiable, Hashable {
        let path: String
        /// From the "[Jitnote] name" description when this app created it, else the repository name.
        let displayName: String
        let cloneUrl: String
        let isNotebook: Bool
        let isPrivate: Bool
        /// Login of the user or organization that owns it.
        let owner: String
        let updatedAt: Int64?
        let sizeKb: Int64?

        var id: String { cloneUrl }
    }

    struct NameTaken: Error {}

    static let notebookMark = "[Jitnote]"
    private static let pageSize = 100
    private static let maxPages = 5

    static func verify(_ provider: Provider, token: String) async throws -> User {
        let url = provider == .github ? "https://api.github.com/user" : "https://gitee.com/api/v5/user"
        guard let user = try await request(provider, token: token, method: "GET", url: url) as? [String: Any],
              let login = string(user["login"])
        else { throw SyncError(.other, "无法读取账号信息") }
        let id = string(user["id"]) ?? ""
        let email = string(user["email"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? (provider == .github ? "\(id)+\(login)@users.noreply.github.com" : "\(id)+\(login)@user.noreply.gitee.com")
        return User(login: login, email: email)
    }

    /// Repositories the account owns or collaborates on: this app's notebooks first, then most recently updated.
    static func listRepos(_ provider: Provider, token: String) async throws -> [RemoteRepo] {
        let base = provider == .github
            ? "https://api.github.com/user/repos?sort=updated&affiliation=owner,collaborator,organization_member"
            : "https://gitee.com/api/v5/user/repos?sort=updated&type=all"
        var repos: [RemoteRepo] = []
        for page in 1...maxPages {
            let batch = try await request(provider, token: token, method: "GET", url: "\(base)&per_page=\(pageSize)&page=\(page)") as? [Any] ?? []
            repos += parseRepos(batch)
            if batch.count < pageSize { break }
        }
        var seen = Set<String>()
        return repos.filter { seen.insert($0.cloneUrl).inserted }
            .sorted { ($0.isNotebook ? 1 : 0, $0.updatedAt ?? 0) > ($1.isNotebook ? 1 : 0, $1.updatedAt ?? 0) }
    }

    static func createPrivateRepo(_ provider: Provider, token: String, name: String, path: String) async throws -> CreatedRepo {
        let description = "\(notebookMark) \(name)"
        switch provider {
        case .github:
            let body: [String: Any] = [
                "name": path, "description": description, "private": true, "auto_init": true,
                "has_issues": false, "has_wiki": false, "has_projects": false,
            ]
            let repo = try await request(provider, token: token, method: "POST", url: "https://api.github.com/user/repos", body: body) as? [String: Any]
            guard let clone = string(repo?["clone_url"]), let web = string(repo?["html_url"]) else { throw SyncError(.other, "云端返回了无法识别的内容") }
            return CreatedRepo(cloneUrl: clone, webUrl: web)
        case .gitee:
            let body: [String: Any] = [
                "name": name, "path": path, "description": description, "private": true, "auto_init": true,
                "has_issues": false, "has_wiki": false,
            ]
            let repo = try await request(provider, token: token, method: "POST", url: "https://gitee.com/api/v5/user/repos", body: body) as? [String: Any]
            guard let html = string(repo?["html_url"]) else { throw SyncError(.other, "云端返回了无法识别的内容") }
            let web = html.hasSuffix(".git") ? String(html.dropLast(4)) : html
            return CreatedRepo(cloneUrl: "\(web).git", webUrl: web)
        case .other:
            throw SyncError(.other, "这种账号不能在这里新建笔记本")
        }
    }

    private static func request(_ provider: Provider, token: String, method: String, url: String, body: [String: Any]? = nil) async throws -> Any {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Jitnote-Mac", forHTTPHeaderField: "User-Agent")
        if provider == .github {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        } else {
            request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SyncError(.network, "网络连接失败，请检查网络后重试")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        if (200..<300).contains(code), let json { return json }
        if (200..<300).contains(code) { throw SyncError(.other, "云端返回了无法识别的内容") }

        let message = string((json as? [String: Any])?["message"]) ?? String(decoding: data.prefix(200), as: UTF8.self)
        switch code {
        case 401: throw SyncError(.auth, "令牌不对或已过期，请重新生成后粘贴")
        case 403: throw SyncError(.auth, "令牌缺少需要的权限，请按步骤重新生成：\(message)")
        case 400, 422:
            if message.localizedCaseInsensitiveContains("exist") || message.contains("已存在") { throw NameTaken() }
            throw SyncError(.other, message)
        default: throw SyncError(.other, "云端请求失败（\(code)）：\(message)")
        }
    }

    /// Reads a GitHub or Gitee repository list; both use the same field names for what we need.
    static func parseRepos(_ array: [Any]) -> [RemoteRepo] {
        array.compactMap { element in
            guard let repo = element as? [String: Any], var web = string(repo["html_url"]) else { return nil }
            if web.hasSuffix(".git") { web = String(web.dropLast(4)) }
            // Gitee: "path" is the URL part, "name" may be Chinese. GitHub: "name" is the URL part.
            let path = string(repo["path"]) ?? string(repo["name"]) ?? web.components(separatedBy: "/").last ?? web
            let description = string(repo["description"]) ?? ""
            let marked = description.hasPrefix(notebookMark)
            let owner = string((repo["owner"] as? [String: Any])?["login"])
                ?? string((repo["namespace"] as? [String: Any])?["path"])
                ?? web.components(separatedBy: "/").dropLast().last ?? ""
            let updated = (string(repo["pushed_at"]) ?? string(repo["updated_at"])).flatMap(parseDate)
            return RemoteRepo(
                path: path,
                displayName: marked
                    ? description.dropFirst(notebookMark.count).trimmingCharacters(in: .whitespaces)
                    : string(repo["name"]) ?? path,
                cloneUrl: string(repo["clone_url"]) ?? "\(web).git",
                isNotebook: marked,
                isPrivate: repo["private"] as? Bool ?? true,
                owner: owner,
                updatedAt: updated,
                sizeKb: (repo["size"] as? NSNumber)?.int64Value
            )
        }
    }

    private static func parseDate(_ text: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): number.stringValue
        default: nil
        }
    }
}

enum RepoUrls {
    /// The same repository written differently (case, trailing "/", ".git") gives the same key.
    static func key(of url: String) -> String {
        var key = url.trimmingCharacters(in: .whitespaces).lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        if key.hasSuffix(".git") { key.removeLast(4) }
        return key
    }

    private static let knownHosts: Set<String> = ["github.com", "www.github.com", "gitee.com", "www.gitee.com"]

    /// Turns what people paste (often the browser address, e.g. ".../tree/master/docs") into a
    /// clone URL. GitHub and Gitee repositories are always owner/name; other hosts are kept as is.
    static func toCloneUrl(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host?.lowercased(), knownHosts.contains(host) else { return text }
        let segments = url.path.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return text }
        let name = segments[1].hasSuffix(".git") ? String(segments[1].dropLast(4)) : segments[1]
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return "https://\(bareHost)/\(segments[0])/\(name).git"
    }
}

enum RepoNames {
    /// Repository path derived from a display name; Chinese-only names get a random path.
    static func fromName(_ name: String) -> String {
        let lowered = name.lowercased()
        var slug = lowered.replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-._")).prefix(60))
        return slug.count >= 2 && slug.first!.isLetter ? slug : "notes-\(randomSuffix())"
    }

    static func randomSuffix() -> String {
        String((0..<6).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! })
    }

    static func isValid(_ path: String) -> Bool {
        path.range(of: "^[A-Za-z][A-Za-z0-9._-]{1,99}$", options: .regularExpression) != nil
    }
}
