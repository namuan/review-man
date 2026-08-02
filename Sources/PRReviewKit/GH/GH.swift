import Foundation

public enum GitHubError: Error, CustomStringConvertible {
    /// gh CLI is not installed or not authenticated.
    case ghUnavailable(String)
    /// A gh subprocess exited non-zero.
    case commandFailed(command: String, stderr: String)
    /// gh ran but returned a GraphQL/API error payload.
    case api(String)
    /// Response could not be decoded.
    case parse(String)
    /// The process timed out.
    case timeout(String)

    public var description: String {
        switch self {
        case .ghUnavailable(let s):
            return s
        case .commandFailed(let cmd, let err):
            let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Command failed: \(cmd)" + (trimmed.isEmpty ? "" : "\n\(trimmed)")
        case .api(let s):
            return "GitHub API error: \(s)"
        case .parse(let s):
            return "Parse error: \(s)"
        case .timeout(let s):
            return "Timed out: \(s)"
        }
    }
}

/// Thin wrapper around the `gh` CLI. Child stdout/stderr go to temp files to
/// avoid pipe deadlocks; a timeout kills runaway processes.
public enum GH {

    public struct Result {
        public let data: Data
        public let stderr: String
    }

    private static let timeoutInterval: TimeInterval = 120

    public static func ensureGH() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["gh", "--version"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw GitHubError.ghUnavailable(
                "The `gh` GitHub CLI is required but was not found or is not working.\n"
                + "Install it with:  brew install gh\n"
                + "Then authenticate with:  gh auth login"
            )
        }
    }

    public static func run(_ args: [String], timeout: TimeInterval = 120) throws -> Result {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let outURL = tmp.appendingPathComponent("prr-out-\(UUID().uuidString)")
        let errURL = tmp.appendingPathComponent("prr-err-\(UUID().uuidString)")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["gh"] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LC_ALL"] = "en_US.UTF-8"
        env["CLICOLOR"] = "0"
        env["NO_COLOR"] = "1"
        proc.environment = env

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        proc.standardOutput = outHandle
        proc.standardError = errHandle

        let command = "gh " + args.joined(separator: " ")
        try proc.run()

        var timedOut = false
        let killItem = DispatchWorkItem { [weak proc] in
            if let proc, proc.isRunning {
                timedOut = true
                proc.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killItem)
        proc.waitUntilExit()
        killItem.cancel()

        try outHandle.close()
        try errHandle.close()
        let data = fm.contents(atPath: outURL.path) ?? Data()
        let errStr = String(data: fm.contents(atPath: errURL.path) ?? Data(), encoding: .utf8) ?? ""
        try? fm.removeItem(at: outURL)
        try? fm.removeItem(at: errURL)

        guard proc.terminationStatus == 0 else {
            if timedOut {
                throw GitHubError.timeout(command)
            }
            throw GitHubError.commandFailed(command: command, stderr: errStr)
        }
        return Result(data: data, stderr: errStr)
    }

    public static func runJSON<T: Decodable>(_ args: [String]) throws -> T {
        let r = try run(args)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: r.data)
        } catch {
            throw GitHubError.parse("Could not decode response for: \(args.first ?? "gh api")")
        }
    }

    /// Runs `gh api graphql` with a query string and string variables.
    /// Surfaces GraphQL `errors` payloads as `.api`.
    public static func runGraphQL<T: Decodable>(query: String, variables: [String: String]) throws -> T {
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (k, v) in variables.sorted(by: { $0.key < $1.key }) {
            args.append("-F")
            args.append("\(k)=\(v)")
        }
        let r = try run(args)
        let decoder = JSONDecoder()
        guard let env = try? decoder.decode(GQLEnvelope<T>.self, from: r.data) else {
            throw GitHubError.parse("Could not decode GraphQL response")
        }
        if let errors = env.errors, !errors.isEmpty {
            throw GitHubError.api(errors.map { $0.message }.joined(separator: "\n"))
        }
        guard let data = env.data else {
            throw GitHubError.api("Empty GraphQL response")
        }
        return data
    }
}

private struct GQLEnvelope<T: Decodable>: Decodable {
    struct Err: Decodable { let message: String }
    let data: T?
    let errors: [Err]?
}
