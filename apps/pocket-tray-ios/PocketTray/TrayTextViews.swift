import SwiftUI

struct SensitiveTrayRow: View {
    let item: TrayItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("Sensitive content hidden")
                    .font(.headline)
                Text(reasonDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Use the options button to reveal or correct this warning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sensitive-content-cover")
        .accessibilityLabel(
            "\(kindName) object. Sensitive content hidden. \(reasonDescription) Use Object options to reveal or correct this warning."
        )
    }

    private var reasonDescription: String {
        let labels = item.sensitivity.map {
            SensitiveContentReason.ordered($0.reasons).map(\.warningLabel)
        } ?? []
        guard !labels.isEmpty else { return "Pocket Tray found a possible secret." }
        return "Possible \(labels.joined(separator: " or "))."
    }

    private var kindName: String {
        switch item.kind {
        case .image: "Image"
        case .pdf: "PDF"
        case .text: "Text"
        case .url: "Link"
        }
    }
}

struct TrayTextRow: View {
    let item: TrayItem
    let collectionName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .url ? "link" : "text.alignleft")
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                if let title = item.title {
                    Text(title).font(.headline)
                }
                if item.kind == .url {
                    if item.title == nil {
                        Text(URL(string: item.text)?.host() ?? "Link").font(.headline)
                    }
                    Text(item.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(item.text).foregroundStyle(.primary).lineLimit(4)
                }

                if let note = item.note {
                    Text(note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }

                if let collectionName {
                    Label(collectionName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                lifecycleLabel
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var lifecycleLabel: some View {
        if let trashedAt = item.trashedAt {
            Text("Deleted \(trashedAt, format: .relative(presentation: .named))")
        } else if item.isPinned {
            Text("Does not expire")
        } else if let expiresAt = item.expiresAt {
            Text("Expires \(expiresAt, format: .relative(presentation: .named))")
        } else {
            Text(item.capturedAt, format: .relative(presentation: .named))
        }
    }

    private var accessibilitySummary: String {
        var parts = [item.kind == .url ? "Link" : "Text"]
        if let title = item.title { parts.append(title) }
        parts.append(item.text)
        if let note = item.note { parts.append("Note \(note)") }
        if let collectionName { parts.append("Collection \(collectionName)") }
        if let trashedAt = item.trashedAt {
            parts.append("Deleted \(trashedAt.formatted(.relative(presentation: .named)))")
        } else if item.isPinned {
            parts.append("Pinned, does not expire")
        } else if let expiresAt = item.expiresAt {
            parts.append("Expires \(expiresAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: ". ")
    }
}
