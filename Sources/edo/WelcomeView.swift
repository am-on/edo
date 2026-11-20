import AVFoundation
import QuickLookThumbnailing
import SwiftUI

/// The open button under the heading, then recent videos from Desktop and Downloads side by side.
struct WelcomeView: View {
    @Environment(EditorStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @State private var left: Result<[RecentVideo], Error>?
    @State private var right: Result<[RecentVideo], Error>?
    private let folders = RecentVideos.folders

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Pick a recording to edit")
                    .font(.title2.weight(.semibold))
                Text("Edo keeps your talking at normal speed and speeds up the quiet parts.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        store.presentOpenPanel()
                    } label: {
                        Label("Open Video…", systemImage: "folder")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    Button {
                        recorder.openSetup()
                    } label: {
                        Label("Record Screen…", systemImage: "record.circle")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                }
                .controlSize(.large)
                Text("or drop a video anywhere in this window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                RecentColumn(title: folders.left.lastPathComponent, videos: left)
                RecentColumn(title: folders.right.lastPathComponent, videos: right)
            }
            .frame(maxWidth: 1100, maxHeight: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
    }

    private func reload() {
        left = Result { try RecentVideos.list(in: folders.left) }
        right = Result { try RecentVideos.list(in: folders.right) }
    }
}

private struct RecentColumn: View {
    let title: String
    let videos: Result<[RecentVideo], Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
                if case let .success(videos) = videos, !videos.isEmpty {
                    Text(videos.count == 1 ? "1 video" : "\(videos.count) videos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            Group {
                switch videos {
                case .none:
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure:
                    message("Edo can't read your \(title) folder. Allow access in System Settings › Privacy & Security › Files and Folders.")
                case let .success(videos) where videos.isEmpty:
                    message("No videos in \(title) yet.")
                case let .success(videos):
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                                if index > 0 {
                                    Divider().padding(.leading, 92)
                                }
                                RecentRow(video: video)
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecentRow: View {
    @Environment(EditorStore.self) private var store
    let video: RecentVideo
    @State private var thumbnail: NSImage?
    @State private var length: Double?
    /// Nil until the file has been checked for an audio track.
    @State private var hasSound: Bool?
    @State private var isHovered = false

    var body: some View {
        Button {
            Task { await store.open(video.url) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 72, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(hasSound == false ? 0.45 : 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(video.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(hasSound == false ? .secondary : .primary)
                    HStack(spacing: 6) {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if hasSound == false {
                            tag("No sound", color: .gray)
                                .help("This recording has no audio, so Edo can't find speech in it.")
                        }
                        if video.hasPlan {
                            tag("Edited", color: .blue)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHovered ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(video.url.path)
        .task(id: video.url) { await loadPreview() }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var details: String {
        let added = video.added.formatted(.relative(presentation: .named))
        guard let length else { return added }
        return "\(added) · \(clock(length).replacingOccurrences(of: #"\.\d$"#, with: "", options: .regularExpression))"
    }

    private func loadPreview() async {
        let request = QLThumbnailGenerator.Request(
            fileAt: video.url, size: CGSize(width: 192, height: 120), scale: 2, representationTypes: .thumbnail
        )
        thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        let asset = AVURLAsset(url: video.url)
        length = try? await asset.load(.duration).seconds
        if let tracks = try? await asset.loadTracks(withMediaType: .audio) {
            hasSound = !tracks.isEmpty
        }
    }
}
