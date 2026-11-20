import XCTest

@testable import edo

final class RecentVideosTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func touch(_ name: String) throws {
        try Data().write(to: folder.appendingPathComponent(name))
    }

    func testListsOnlyVideosAndSkipsExportsAndHiddenFiles() throws {
        for name in ["demo.mov", "talk.mp4", "notes.txt", "demo-edited.mov", ".secret.mov", "demo.plan.txt"] {
            try touch(name)
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("folder.mov"), withIntermediateDirectories: true)

        let videos = try RecentVideos.list(in: folder)
        XCTAssertEqual(Set(videos.map(\.name)), ["demo.mov", "talk.mp4"])
        XCTAssertEqual(videos.first { $0.name == "demo.mov" }?.hasPlan, true)
        XCTAssertEqual(videos.first { $0.name == "talk.mp4" }?.hasPlan, false)
    }

    func testMissingFolderThrows() {
        XCTAssertThrowsError(try RecentVideos.list(in: folder.appendingPathComponent("missing")))
    }

    func testNewestComeFirstAndListIsCapped() {
        let videos = (1...7).map { day in
            RecentVideo(url: URL(fileURLWithPath: "/v/\(day).mov"), added: Date(timeIntervalSince1970: Double(day) * 86_400), hasPlan: false)
        }
        XCTAssertEqual(RecentVideos.newest(videos, limit: 5).map(\.name), ["7.mov", "6.mov", "5.mov", "4.mov", "3.mov"])
    }
}
