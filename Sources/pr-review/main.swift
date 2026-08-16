import Foundation
import PRReviewKit

// The `pr-review` executable is a thin launcher for the desktop app. It
// resolves a PR reference into a `pr-review://` URL and hands it to the app
// through LaunchServices (the app must have been launched once so the scheme
// is registered). The terminal UI was removed in the desktop migration.

let version = "2.0.0"

let usage = """
pr-review \(version) — desktop launcher for PR Review

Usage:
  pr-review [options] <pr-ref>
  pr-review --demo

PR references:
  https://github.com/owner/repo/pull/123
  owner/repo#123
  123                      (resolved against the current repository)

Options:
  --demo            Open the desktop app in offline demo mode
  --help, -h        Show this help
  --version, -V     Show version

Requirements:
  macOS 13+ (Apple Silicon) and the GitHub CLI (`gh`) installed and
  authenticated (`gh auth login`). The PR Review app must have been
  launched once so the `pr-review://` URL scheme is registered.
"""

func launchApp(arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

/// Resolves `owner/repo` for the current working directory using `gh`.
func currentRepositoryOwnerRepo() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? nil : name
}

let args = Array(CommandLine.arguments.dropFirst())
AppLog.info("launcher", "Launcher started; argumentCount=\(args.count)")

// Options handled by the launcher itself (the parser defers these to us).
if args.contains("--version") || args.contains("-V") {
    print("pr-review \(version) — desktop launcher for PR Review")
    exit(0)
}
if args.contains("--help") || args.contains("-h") {
    print(usage, terminator: "")
    exit(0)
}

switch LauncherRequestParser.parse(args) {
case .invalid(let reason):
    AppLog.warning("launcher", "Rejected launch request: \(reason)")
    fputs("pr-review: \(reason)\n\n", stderr)
    fputs(usage, stderr)
    exit(2)

case .demo:
    AppLog.info("launcher", "Opening demo application")
    if launchApp(arguments: ["-a", "PR Review", "--args", "--demo"]) {
        exit(0)
    }
    fputs("pr-review: could not open PR Review (is the app installed?)\n", stderr)
    exit(1)

case .open(let reference):
    AppLog.info("launcher", "Opening PR reference \(reference)")
    // A bare number resolves against the current repository via `gh`.
    let resolved: String
    if reference.allSatisfy({ $0.isNumber }) {
        guard let ownerRepo = currentRepositoryOwnerRepo() else {
            fputs("pr-review: cannot resolve PR \(reference) — not in a GitHub repository?\n", stderr)
            fputs("Use a full URL or owner/repo#\(reference) instead.\n", stderr)
            exit(1)
        }
        resolved = "\(ownerRepo)#\(reference)"
    } else {
        resolved = reference
    }

    guard let url = LauncherRequestParser.appURL(for: resolved) else {
        fputs("pr-review: unrecognized PR reference '\(reference)'.\n", stderr)
        fputs("Expected a GitHub URL (https://github.com/owner/repo/pull/N) or owner/repo#N.\n", stderr)
        exit(2)
    }
    AppLog.info("launcher", "Handing off to application URL \(url)")
    if launchApp(arguments: [url]) {
        exit(0)
    }
    fputs("pr-review: could not open \(url) — is the PR Review app installed?\n", stderr)
    exit(1)
}
