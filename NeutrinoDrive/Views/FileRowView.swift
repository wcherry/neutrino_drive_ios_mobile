import SwiftUI

// MARK: - FileRowView

/// A list row representing a single DriveItem, showing its icon, name, size, and date.
struct FileRowView: View {

    // MARK: - Parameters

    let item: DriveItem

    // MARK: - Body

    var body: some View {
        HStack(spacing: 12) {
            FileTypeIcon(kind: item.kind)
            textStack
            Spacer()
            badgeIcons
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Text

    private var textStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.body)
                .lineLimit(1)
            Text(subtitleText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let size = item.size {
            parts.append(formattedSize(size))
        }
        parts.append(formattedDate(item.modifiedAt))
        return parts.joined(separator: " · ")
    }

    // MARK: - Badge Icons

    private var badgeIcons: some View {
        HStack(spacing: 6) {
            if item.isShared {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Shared")
            }
            if item.isTrashed {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("In Trash")
            }
            if item.type == .folder {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        // The type is spoken as well as drawn — the icon is the only thing distinguishing a
        // Sheet from a Slide visually, and VoiceOver users get nothing from it.
        var components = [item.name, item.kind.accessibilityDescription]
        if item.type == .file, let size = item.size {
            components.append(formattedSize(size))
        }
        components.append("Modified \(formattedDate(item.modifiedAt))")
        if item.isShared { components.append("Shared") }
        if item.isTrashed { components.append("In Trash") }
        return components.joined(separator: ", ")
    }

    // MARK: - Formatting Helpers

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview

#Preview {
    // One row per icon treatment worth eyeballing: a folder, the six Neutrino natives, a
    // couple of ordinary types, and a file the server could only describe as
    // octet-stream — whose icon has to come from its extension.
    let samples: [(String, String?)] = [
        ("Photos", nil),
        ("Product Plan", NeutrinoMIME.doc),
        ("Q3 Budget", NeutrinoMIME.sheet),
        ("Kickoff Deck", NeutrinoMIME.slide),
        ("System Architecture", NeutrinoMIME.diagram),
        ("Logo Sketch", NeutrinoMIME.drawing),
        ("Standup Notes", NeutrinoMIME.note),
        ("Q3 Report.pdf", "application/pdf"),
        ("Sunset.heic", "image/heic"),
        ("Keynote.mp4", "video/mp4"),
        ("archive.zip", "application/zip"),
        ("Contract.docx", "application/octet-stream"),
        ("mystery.bin", "application/octet-stream"),
    ]
    return List {
        ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
            FileRowView(item: DriveItem(
                id: "\(index)",
                name: sample.0,
                type: sample.1 == nil ? .folder : .file,
                parentID: nil,
                size: sample.1 == nil ? nil : 1_024_512,
                modifiedAt: Date().addingTimeInterval(-86400),
                isTrashed: false,
                isShared: index == 1,
                mimeType: sample.1
            ))
        }
    }
}
