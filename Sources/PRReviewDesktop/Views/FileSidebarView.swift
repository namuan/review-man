import SwiftUI
import PRReviewKit

/// Collapsible file sidebar: native search, status letters, ± counts, comment
/// badges, binary/too-large markers, and viewed checkmarks.
public struct FileSidebarView: View {
    @ObservedObject public var store: ReviewSessionStore

    public init(store: ReviewSessionStore) {
        self.store = store
    }

    public var body: some View {
        List(selection: Binding(
            get: { store.selection.filePath },
            set: { store.select(filePath: $0) }
        )) {
            Section("Files") {
                ForEach(store.filteredSidebarItems) { item in
                    row(item)
                        .tag(item.path)
                        .accessibilityIdentifier("sidebar-row-\(item.path)")
                }
            }
        }
        .searchable(text: $store.sidebarSearch, prompt: "Filter files")
        .navigationTitle("Files")
        .accessibilityIdentifier("file-sidebar")
    }

    private func row(_ item: FileSidebarItem) -> some View {
        HStack(spacing: 6) {
            Text(item.statusLetter)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor(item.statusLetter))
                .frame(width: 14)
                .accessibilityLabel("status \(item.statusLetter)")

            Text(displayPath(item))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if item.isBinary {
                Text("B").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("binary")
            }
            if item.tooLarge {
                Text("!").font(.caption2).foregroundStyle(.orange)
                    .accessibilityLabel("diff too large")
            }
            if item.threadCount > 0 {
                Text("● \(item.threadCount)")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .accessibilityLabel("\(item.threadCount) comments")
            }
            if item.isViewed {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityLabel("viewed")
            }
            if let additions = item.additions, let deletions = item.deletions {
                Text("+\(additions) −\(deletions)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("--")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("counts unavailable")
            }
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button(item.isViewed ? "Mark Unviewed" : "Mark Viewed") {
                store.toggleViewed(filePath: item.path)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayPath(item)), status \(item.statusLetter)\(item.threadCount > 0 ? ", \(item.threadCount) comments" : "")\(item.isViewed ? ", viewed" : "")")
    }

    private func displayPath(_ item: FileSidebarItem) -> String {
        guard let old = item.oldPath, old != item.path, item.statusLetter == "R" else {
            return item.path
        }
        return "\(old) → \(item.path)"
    }

    private func statusColor(_ letter: String) -> SwiftUI.Color {
        switch letter {
        case "A": return .green
        case "D": return .red
        case "R": return .blue
        default: return .secondary
        }
    }
}
