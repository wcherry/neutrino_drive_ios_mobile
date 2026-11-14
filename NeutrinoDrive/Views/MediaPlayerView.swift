import SwiftUI
import AVKit

// MARK: - MediaPlayerView

/// Full-screen player for a Drive video or audio file that is being **streamed** — decrypted
/// range by range as it plays, rather than downloaded and decrypted in full first.
///
/// Only reached when `StreamingPlaybackService.shouldStream(mimeType:sizeBytes:)` is true.
/// Everything else keeps going through the existing download-then-QuickLook path, which is both
/// simpler and fully authenticated.
///
/// The status line is not decoration. Streamed bytes are not integrity-checked (see
/// `EncryptedMediaStream`), and a product that encrypts end to end should say so where the
/// trade is actually being made rather than only in a source comment.
struct MediaPlayerView: View {

    let item: DriveItem

    @EnvironmentObject private var streamingService: StreamingPlaybackService
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(item.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await start() }
        .onDisappear(perform: stop)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableCompat(
                title: "Can't stream this file",
                message: loadError,
                systemImage: "exclamationmark.triangle"
            )
        } else if let player {
            VStack(spacing: 0) {
                VideoPlayer(player: player)
                integrityNotice
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing stream…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// States the one thing a user could not otherwise know: these bytes were not verified.
    private var integrityNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
            Text("Streaming decrypts only the parts you play, so this file's integrity check "
                 + "can't be completed. Download it to verify it in full.")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lifecycle

    private func start() async {
        guard player == nil, loadError == nil else { return }
        do {
            let newItem = try await streamingService.makeStreamingPlayerItem(
                fileID: item.id,
                mimeType: item.mimeType ?? "video/mp4"
            )
            playerItem = newItem
            player = AVPlayer(playerItem: newItem)
            player?.play()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func stop() {
        player?.pause()
        if let playerItem { streamingService.release(item: playerItem) }
        player = nil
        playerItem = nil
    }
}

// MARK: - ContentUnavailableCompat

/// `ContentUnavailableView` is iOS 17+; this project's floor is iOS 16.
struct ContentUnavailableCompat: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
