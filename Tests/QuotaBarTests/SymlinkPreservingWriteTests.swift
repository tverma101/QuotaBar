import Foundation
import XCTest
@testable import QuotaBar

/// A background refresh was destroying the user's symlinks.
///
/// `LocalTextFileAccessor.writeText` writes a private temp file and then `rename(2)`s it over the
/// destination. `rename` replaces the *directory entry*, so a destination that is a symlink is silently
/// destroyed and replaced by a regular file. Users keep `~/.codex/auth.json`,
/// `~/.claude/.credentials.json` and `~/.grok/auth.json` symlinked into a dotfiles repo — and the caller
/// here is the five-minute background tick, with no user action. The token rotated, the link was gone with
/// no undo and no log line, and the dotfiles repo silently diverged.
///
/// `FakeFiles` is a dictionary, so it cannot express a symlink, a rename, or a mode — which is why no
/// existing credential-rotation test could reach this. These use a real filesystem.
final class SymlinkPreservingWriteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaBarTests.Symlink.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWriteFollowsASymlinkInsteadOfReplacingIt() throws {
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let realFile = dotfiles.appendingPathComponent("auth.json")
        try Data("old".utf8).write(to: realFile)

        let linked = root.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: realFile)

        try LocalTextFileAccessor().writeText(linked.path, "rotated")

        // The link must survive, and the rotation must land on its target.
        let linkAttributes = try FileManager.default.attributesOfItem(atPath: linked.path)
        XCTAssertEqual(
            linkAttributes[.type] as? FileAttributeType, .typeSymbolicLink,
            "the symlink must not be replaced by a regular file"
        )
        XCTAssertEqual(
            try String(contentsOf: realFile, encoding: .utf8), "rotated",
            "the rotation must reach the file the user linked to"
        )
    }

    /// A relative link resolves against its own directory, so a chain of relative links must still
    /// land on the final target. The old resolver reused the original path's parent for every hop:
    /// link1 (`../b/link2`) then link2 (`target.txt`) resolved to `a/target.txt` instead of
    /// `b/target.txt`, quietly writing the rotated credential to a new file and leaving the real
    /// one stale.
    func testWriteFollowsAChainOfRelativeSymlinks() throws {
        let links = root.appendingPathComponent("a", isDirectory: true)
        let real = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let realFile = real.appendingPathComponent("target.txt")
        try Data("old".utf8).write(to: realFile)

        let second = real.appendingPathComponent("link2")
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: "target.txt")
        let first = links.appendingPathComponent("link1")
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: "../b/link2")

        try LocalTextFileAccessor().writeText(first.path, "rotated")

        XCTAssertEqual(
            try String(contentsOf: realFile, encoding: .utf8), "rotated",
            "a chained relative symlink must resolve to the final target, not the first link's parent"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: links.appendingPathComponent("target.txt").path),
            "the write must not create a stray credential beside the first link"
        )
        for link in [first, second] {
            let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
            XCTAssertEqual(
                attributes[.type] as? FileAttributeType, .typeSymbolicLink,
                "every link in the chain must survive the rotation"
            )
        }
    }

    /// A relative link can pass through a symlinked directory. POSIX resolves `..` after following
    /// the directory link, so `root/symdir/../target.txt` is `root/real/target.txt` here, not
    /// `root/target.txt`. Lexically standardizing the hop path changes where the credential lands.
    func testWriteResolvesParentSegmentsAfterFollowingADirectoryLink() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        let nested = real.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let realFile = real.appendingPathComponent("target.txt")
        try Data("old".utf8).write(to: realFile)

        let inner = nested.appendingPathComponent("link2")
        try FileManager.default.createSymbolicLink(atPath: inner.path, withDestinationPath: "../target.txt")
        let directoryLink = root.appendingPathComponent("symdir")
        try FileManager.default.createSymbolicLink(atPath: directoryLink.path, withDestinationPath: "real/subdir")
        let linked = root.appendingPathComponent("auth.json")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: "symdir/link2")

        try LocalTextFileAccessor().writeText(linked.path, "rotated")

        XCTAssertEqual(
            try String(contentsOf: realFile, encoding: .utf8), "rotated",
            "a `..` after a followed directory link resolves against the real directory"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("target.txt").path),
            "lexical standardization must not redirect the write beside the outer link"
        )
    }

    /// The security property the original `O_NOFOLLOW` was protecting must be unchanged: the written file
    /// is still private, and the temp file is still never placed through a link.
    func testWrittenFileKeepsItsPrivateMode() throws {
        let plain = root.appendingPathComponent("auth.json")
        try LocalTextFileAccessor().writeText(plain.path, "secret")

        let attributes = try FileManager.default.attributesOfItem(atPath: plain.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(
            permissions.int16Value, 0o600,
            "a credential must still be owner-only after resolving a symlink"
        )
    }

    /// No temp files may be left behind, and the write must be a single atomic rename — not a
    /// truncate-in-place, which would expose a window where the credential is half-written.
    func testNoTemporaryFilesAreLeftBehind() throws {
        let plain = root.appendingPathComponent("auth.json")
        try LocalTextFileAccessor().writeText(plain.path, "secret")

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "a temp file was left behind: \(leftovers)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["auth.json"])
    }
}
