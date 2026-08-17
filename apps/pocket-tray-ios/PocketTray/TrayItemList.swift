import SwiftUI

enum TrayItemPeriod: CaseIterable, Hashable {
    case today
    case yesterday
    case earlier

    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .yesterday: String(localized: "Yesterday")
        case .earlier: String(localized: "Earlier")
        }
    }
}

struct TrayItemSection: Identifiable, Equatable {
    let period: TrayItemPeriod
    let items: [TrayItem]

    var id: TrayItemPeriod { period }

    static func group(
        _ items: [TrayItem],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [TrayItemSection] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let grouped = Dictionary(grouping: items) { item in
            if item.capturedAt >= today { return TrayItemPeriod.today }
            if item.capturedAt >= yesterday { return TrayItemPeriod.yesterday }
            return TrayItemPeriod.earlier
        }
        return TrayItemPeriod.allCases.compactMap { period in
            grouped[period].map { TrayItemSection(period: period, items: $0) }
        }
    }
}

enum QuickCopyPolicy {
    static func shouldCopyOnTap(_ item: TrayItem, isEnabled: Bool) -> Bool {
        guard isEnabled, !item.protectsSensitivePreview else { return false }
        return item.kind == .text || item.kind == .url
    }
}

enum QuickCopyPreference {
    static let key = "interaction.quickCopyOnTap"
    @MainActor
    static let defaults = UserDefaults(
        suiteName: FileTrayRepository.appGroupIdentifier
    ) ?? .standard
}

struct TrayItemActions {
    let showDetail: (TrayItem) -> Void
    let previewImage: (TrayItem) -> Void
    let previewPDF: (TrayItem) -> Void
    let copy: (TrayItem) -> Void
    let open: (TrayItem) -> Void
    let assignCollection: (TrayItem) -> Void
    let edit: (TrayItem) -> Void
    let setPinned: (TrayItem, Bool) -> Void
    let moveToTrash: (TrayItem) -> Void
    let restore: (TrayItem) -> Void
    let deletePermanently: (TrayItem) -> Void
    let overrideSensitivity: (TrayItem) -> Void
    let performSuggestedAction: (ContentAction) -> Void
}

struct TrayItemList: View {
    let items: [TrayItem]
    let collections: [TrayCollection]
    let tray: Tray
    let isTrash: Bool
    let groupsByCaptureDate: Bool
    let quickCopyOnTap: Bool
    @Binding var sensitivePreviewSession: SensitivePreviewSession
    let actions: TrayItemActions

    var body: some View {
        List {
            if groupsByCaptureDate {
                ForEach(TrayItemSection.group(items)) { section in
                    Section(section.period.title) {
                        ForEach(section.items) { item in
                            itemRow(item)
                        }
                    }
                }
            } else {
                ForEach(items) { item in
                    itemRow(item)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(18)
    }

    @ViewBuilder
    private func itemRow(_ item: TrayItem) -> some View {
        let isSensitiveHidden = !sensitivePreviewSession.allowsContentAccess(to: item)
        HStack(spacing: 12) {
            itemContent(item, isSensitiveHidden: isSensitiveHidden)

            if item.protectsSensitivePreview, !isSensitiveHidden {
                Button { sensitivePreviewSession.hide(item.id) } label: {
                    Image(systemName: "eye.slash").imageScale(.large)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hide sensitive content")
            }

            itemOptionsMenu(item, isSensitiveHidden: isSensitiveHidden)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isTrash {
                if !isSensitiveHidden {
                    Button { actions.edit(item) } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                Button { actions.setPinned(item, !item.isPinned) } label: {
                    Label(
                        item.isPinned ? "Unpin" : "Pin",
                        systemImage: item.isPinned ? "pin.slash" : "pin"
                    )
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: !isTrash) {
            if isTrash {
                Button { actions.restore(item) } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.green)
                Button(role: .destructive) { actions.deletePermanently(item) } label: {
                    Label("Delete Permanently", systemImage: "trash.slash")
                }
            } else {
                Button(role: .destructive) { actions.moveToTrash(item) } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func itemContent(_ item: TrayItem, isSensitiveHidden: Bool) -> some View {
        if isSensitiveHidden {
            SensitiveTrayRow(item: item)
        } else if item.kind == .image {
            if isTrash {
                TrayImageRow(item: item, collectionName: collectionName(for: item), tray: tray)
            } else {
                Button { actions.showDetail(item) } label: {
                    TrayImageRow(item: item, collectionName: collectionName(for: item), tray: tray)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityHint("Opens image preview and sharing")
            }
        } else if item.kind == .pdf {
            if isTrash {
                TrayPDFRow(item: item, collectionName: collectionName(for: item), tray: tray)
            } else {
                Button { actions.showDetail(item) } label: {
                    TrayPDFRow(item: item, collectionName: collectionName(for: item), tray: tray)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityHint("Opens PDF preview and sharing")
            }
        } else if isTrash {
            TrayTextRow(item: item, collectionName: collectionName(for: item))
        } else {
            Button {
                if QuickCopyPolicy.shouldCopyOnTap(item, isEnabled: quickCopyOnTap) {
                    actions.copy(item)
                } else {
                    actions.showDetail(item)
                }
            } label: {
                TrayTextRow(item: item, collectionName: collectionName(for: item))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityHint(
                QuickCopyPolicy.shouldCopyOnTap(item, isEnabled: quickCopyOnTap)
                    ? "Copies this \(item.kind == .url ? "link" : "text")"
                    : "Opens object details"
            )
        }
    }

    private func itemOptionsMenu(
        _ item: TrayItem,
        isSensitiveHidden: Bool
    ) -> some View {
        Menu {
            if isSensitiveHidden {
                Button { sensitivePreviewSession.reveal(item.id) } label: {
                    Label("Reveal", systemImage: "eye")
                }
                Button { actions.overrideSensitivity(item) } label: {
                    Label("Mark Not Sensitive", systemImage: "checkmark.shield")
                }
            }
            if isTrash {
                Button { actions.restore(item) } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) { actions.deletePermanently(item) } label: {
                    Label("Delete Permanently", systemImage: "trash.slash")
                }
            } else {
                reuseActions(item, isSensitiveHidden: isSensitiveHidden)
                Button { actions.assignCollection(item) } label: {
                    Label(
                        item.collectionID == nil ? "Add to Collection" : "Move or Remove Collection",
                        systemImage: "folder"
                    )
                }
                if !isSensitiveHidden {
                    Button { actions.edit(item) } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                Button { actions.setPinned(item, !item.isPinned) } label: {
                    Label(
                        item.isPinned ? "Unpin" : "Pin",
                        systemImage: item.isPinned ? "pin.slash" : "pin"
                    )
                }
                Button(role: .destructive) { actions.moveToTrash(item) } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").imageScale(.large)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Object options")
        .accessibilityHint("Shows reuse, collection, edit, pin, and lifecycle actions")
    }

    @ViewBuilder
    private func reuseActions(_ item: TrayItem, isSensitiveHidden: Bool) -> some View {
        if !isSensitiveHidden {
            switch item.kind {
            case .image:
                Button { actions.previewImage(item) } label: {
                    Label("Preview and Share", systemImage: "photo")
                }
            case .pdf:
                Button { actions.previewPDF(item) } label: {
                    Label("Preview and Share", systemImage: "doc.richtext")
                }
            case .text:
                Button { actions.copy(item) } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
            case .url:
                Button { actions.copy(item) } label: {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                Button { actions.open(item) } label: {
                    Label("Open Link", systemImage: "arrow.up.right.square")
                }
            }
            if let suggestedActions = item.analysis?.actions, !suggestedActions.isEmpty {
                SwiftUI.Section("Suggested Actions") {
                    ForEach(suggestedActions) { action in
                        Button { actions.performSuggestedAction(action) } label: {
                            Label(action.suggestedTitle, systemImage: action.systemImage)
                        }
                    }
                }
            }
        }
    }

    private func collectionName(for item: TrayItem) -> String? {
        guard let collectionID = item.collectionID else { return nil }
        return collections.first { $0.id == collectionID }?.name
    }
}

private extension ContentAction {
    var systemImage: String {
        switch kind {
        case .url: "arrow.up.right.square"
        case .phone: "phone"
        case .address: "map"
        case .date: "calendar"
        case .trackingNumber: "shippingbox"
        }
    }
}
