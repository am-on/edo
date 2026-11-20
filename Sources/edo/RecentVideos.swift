import Foundation
import UniformTypeIdentifiers

struct RecentVideo: Identifiable, Equatable, Sendable {
    var url: URL
    /// When the file arrived in its folder, or when it was created if the volume doesn't record that.
    var added: Date
    var hasPlan: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum RecentVideos {
    /// Desktop and Downloads, or two folders from EDO_RECENT_FOLDERS separated by a colon.
    static var folders: (left: URL, right: URL) {
        let paths = ProcessInfo.processInfo.environment["EDO_RECENT_FOLDERS"]?.split(separator: ":").map(String.init) ?? []
        if paths.count == 2 {
            return (URL(fileURLWithPath: paths[0]), URL(fileURLWithPath: paths[1]))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (home.appendingPathComponent("Desktop"), home.appendingPathComponent("Downloads"))
    }

    static func list(in folder: URL, limit: Int = 100) throws -> [RecentVideo] {
        let keys: [URLResourceKey] = [.contentTypeKey, .addedToDirectoryDateKey, .creationDateKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )
        let names = Set(urls.map(\.lastPathComponent))
        let videos = urls.compactMap { url -> RecentVideo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.contentType?.conforms(to: .movie) == true,
                  !url.deletingPathExtension().lastPathComponent.hasSuffix("-edited") else { return nil }
            return RecentVideo(
                url: url,
                added: values.addedToDirectoryDate ?? values.creationDate ?? .distantPast,
                hasPlan: names.contains(PlanFile.url(for: url).lastPathComponent)
            )
        }
        return newest(videos, limit: limit)
    }

    static func newest(_ videos: [RecentVideo], limit: Int) -> [RecentVideo] {
        Array(videos.sorted { ($0.added, $1.name) > ($1.added, $0.name) }.prefix(limit))
    }
}
