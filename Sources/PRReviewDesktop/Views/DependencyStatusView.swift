import SwiftUI
import AppKit
import PRReviewKit

/// Actionable `gh` dependency status: path, source, version, account, scope,
/// and status-specific guidance. Actions never spawn a shell or run `gh auth
/// login` — they only locate/clear/copy/open documentation.
public struct DependencyStatusView: View {
    @ObservedObject public var store: ReviewSessionStore

    public init(store: ReviewSessionStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GitHub CLI Status")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if store.isCheckingDependency {
                    ProgressView().controlSize(.small)
                }
            }

            if let status = store.dependencyStatus {
                statusBody(status)
            } else {
                Text("Not checked yet.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Re-check") { store.recheckDependency() }
                    .disabled(store.isCheckingDependency)
                    .accessibilityIdentifier("dependency-recheck-button")
                Button("Locate Executable…") { locateExecutable() }
                    .accessibilityIdentifier("dependency-locate-button")
                if store.selectedExecutableURL != nil {
                    Button("Clear Selection") {
                        store.clearSelectedExecutable()
                    }
                    .accessibilityIdentifier("dependency-clear-button")
                }
                if let instruction = store.dependencyInstruction {
                    Button("Copy \(instruction)") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(instruction, forType: .string)
                    }
                    .accessibilityIdentifier("dependency-copy-button")
                }
            }
        }
        .padding(16)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dependency-status-view")
    }

    @ViewBuilder
    private func statusBody(_ status: GitHubDependencyStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(stateLabel(status.state), systemImage: stateIcon(status.state))
                .font(.body.weight(.semibold))
                .foregroundStyle(stateColor(status.state))
                .accessibilityIdentifier("dependency-state")

            if let path = status.executableURL?.path {
                Text("Executable: \(path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dependency-path")
            }
            if let source = status.source {
                Text("Discovered: \(sourceLabel(source))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let version = status.version {
                Text("Version: \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let account = status.account {
                Text("Account: \(account)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let scope = status.scopeNote {
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = status.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dependency-message")
            }
        }
    }

    private func locateExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select gh Executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setSelectedExecutable(url)
    }

    private func stateLabel(_ state: GitHubDependencyStatus.State) -> String {
        switch state {
        case .checking: return "Checking…"
        case .ready: return "Ready"
        case .missing: return "GitHub CLI not found"
        case .unusable: return "gh is not usable"
        case .unauthenticated: return "Not authenticated"
        case .expiredOrRevoked: return "Credential expired or revoked"
        case .underScoped: return "Insufficient permissions"
        case .unknownFailure: return "Health check failed"
        }
    }

    private func stateIcon(_ state: GitHubDependencyStatus.State) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .checking: return "clock"
        case .missing: return "questionmark.circle"
        case .unusable: return "xmark.octagon"
        case .unauthenticated, .expiredOrRevoked: return "person.crop.circle.badge.exclamationmark"
        case .underScoped: return "lock"
        case .unknownFailure: return "exclamationmark.triangle"
        }
    }

    private func stateColor(_ state: GitHubDependencyStatus.State) -> SwiftUI.Color {
        switch state {
        case .ready: return .green
        case .checking: return .secondary
        case .missing, .unusable, .unknownFailure: return .orange
        case .unauthenticated, .expiredOrRevoked, .underScoped: return .red
        }
    }

    private func sourceLabel(_ source: GitHubExecutableSource) -> String {
        switch source {
        case .selected: return "user-selected"
        case .inheritedPath: return "PATH"
        case .appleSiliconHomebrew: return "Apple Silicon Homebrew"
        case .intelHomebrew: return "Intel Homebrew"
        case .macPorts: return "MacPorts"
        }
    }
}

/// A compact welcome/failure-screen card exposing the dependency status.
public struct DependencyStatusCard: View {
    @ObservedObject public var store: ReviewSessionStore
    @State private var showSheet = false

    public init(store: ReviewSessionStore) {
        self.store = store
    }

    public var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isCheckingDependency {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(8)
            .background(SwiftUI.Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dependency-status-card")
        .sheet(isPresented: $showSheet) {
            DependencyStatusView(store: store)
        }
    }

    private var status: GitHubDependencyStatus.State? { store.dependencyStatus?.state }

    private var icon: String {
        switch status {
        case .ready: return "checkmark.circle.fill"
        case .missing, .unusable, .unknownFailure: return "questionmark.circle"
        case .unauthenticated, .expiredOrRevoked, .underScoped: return "exclamationmark.triangle"
        default: return "gearshape"
        }
    }

    private var color: SwiftUI.Color {
        switch status {
        case .ready: return .green
        case .missing, .unusable, .unknownFailure, .unauthenticated, .expiredOrRevoked, .underScoped: return .orange
        default: return .secondary
        }
    }

    private var title: String {
        guard let status else { return "GitHub CLI status" }
        switch status {
        case .ready: return "GitHub CLI ready"
        case .checking: return "Checking GitHub CLI…"
        case .missing: return "GitHub CLI not found — click for setup"
        case .unusable: return "GitHub CLI is not usable — click for details"
        case .unauthenticated: return "Not logged in to GitHub — click to set up"
        case .expiredOrRevoked: return "GitHub credential expired — click to fix"
        case .underScoped: return "GitHub token lacks permissions — click to fix"
        case .unknownFailure: return "GitHub CLI check failed — click for details"
        }
    }
}
