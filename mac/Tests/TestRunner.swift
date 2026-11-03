import Foundation

// XCTest needs Xcode, so the tests are plain functions run by this small executable
// (scripts/build-mac.sh --test). Each test gets a fresh temporary folder.

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) throws {
    if !condition { throw TestFailure(description: "\(file):\(line) expectation failed \(message())") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #fileID, line: UInt = #line) throws {
    if actual != expected { throw TestFailure(description: "\(file):\(line) expected \(expected), got \(actual)") }
}

struct TestCase {
    let name: String
    let run: (URL) throws -> Void

    init(_ name: String, _ run: @escaping (URL) throws -> Void) {
        self.name = name
        self.run = run
    }
}

@main
enum TestRunner {
    static func main() {
        let suites: [(String, [TestCase])] = [
            ("NotebookGit", NotebookGitTests.all),
            ("NoteSaver", NoteSaverTests.all),
            ("FolderWatcher", FolderWatcherTests.all),
            ("NotebookFolders", NotebookFolderTests.all),
            ("NoteIndex", NoteIndexTests.all),
            ("FileTree", FileTreeTests.all),
            ("NoteAssets", NoteAssetsTests.all),
            ("AppUpdates", AppUpdatesTests.all),
            ("HostingApi", HostingApiTests.all),
        ]
        var failed = 0
        var total = 0
        for (suite, tests) in suites {
            for test in tests {
                total += 1
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gn-test-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                do {
                    try test.run(dir)
                    print("✓ \(suite).\(test.name)")
                } catch {
                    failed += 1
                    print("✗ \(suite).\(test.name): \(error)")
                }
            }
        }
        print(failed == 0 ? "\n\(total) tests passed" : "\n\(failed) of \(total) tests failed")
        exit(failed == 0 ? 0 : 1)
    }
}
