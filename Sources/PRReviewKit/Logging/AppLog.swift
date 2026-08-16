import Foundation

/// Asynchronous, rolling diagnostic logs for the desktop app and launcher.
///
/// Logs intentionally exclude review/comment bodies and raw `gh` arguments,
/// which may contain credentials or user-authored content. Files are written
/// under `~/Library/Logs/PR Review/` and never block the main thread.
public enum AppLog {

    public enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    /// Current active log file. Older files are named `PRReview.1.log` through
    /// `PRReview.5.log`.
    public static var directoryURL: URL {
        FileLogger.shared.directoryURL
    }

    public static func debug(_ area: String, _ message: @autoclosure () -> String) {
        write(.debug, area: area, message: message())
    }

    public static func info(_ area: String, _ message: @autoclosure () -> String) {
        write(.info, area: area, message: message())
    }

    public static func warning(_ area: String, _ message: @autoclosure () -> String) {
        write(.warning, area: area, message: message())
    }

    public static func error(_ area: String, _ message: @autoclosure () -> String) {
        write(.error, area: area, message: message())
    }

    /// Records an error after redacting token-shaped values and limiting its
    /// length. Prefer contextual messages that do not include user text.
    public static func failure(_ area: String, context: String, error: Error) {
        write(.error, area: area, message: "\(context): \(FileLogger.sanitized(String(describing: error)))")
    }

    private static func write(
        _ level: Level,
        area: String,
        message: @autoclosure () -> String
    ) {
        // Evaluate before queuing: callers often interpolate MainActor-bound
        // view state, which must not be read later from the file-I/O queue.
        FileLogger.shared.write(level: level, area: area, message: message())
    }
}

private final class FileLogger {

    static let shared = FileLogger()

    let directoryURL: URL
    private let currentURL: URL
    private let queue = DispatchQueue(label: "com.prreview.app.file-logger", qos: .utility)
    private let maximumFileSize = 2 * 1024 * 1024
    private let retainedArchiveCount = 5
    private var currentFileSize = 0
    private let timestampFormatter = ISO8601DateFormatter()

    private init(fileManager: FileManager = .default) {
        let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        directoryURL = libraryURL.appendingPathComponent("Logs/PR Review", isDirectory: true)
        currentURL = directoryURL.appendingPathComponent("PRReview.log")
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        queue.async { [weak self] in
            self?.prepareDirectory(fileManager: fileManager)
            self?.writeStartupMarker()
        }
    }

    func write(level: AppLog.Level, area: String, message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = timestampFormatter.string(from: Date())
            let safeArea = Self.sanitized(area)
            let safeMessage = Self.sanitized(message)
            let line = "\(timestamp) [\(level.rawValue)] [\(safeArea)] \(safeMessage)\n"
            append(line)
        }
    }

    private func prepareDirectory(fileManager: FileManager) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            currentFileSize = (try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        } catch {
            // Logging must never affect application behavior.
        }
    }

    private func writeStartupMarker() {
        append("\(timestampFormatter.string(from: Date())) [INFO] [app] Logging started; process=\(ProcessInfo.processInfo.processIdentifier)\n")
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if currentFileSize + data.count > maximumFileSize {
            rollFiles()
        }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: currentURL.path) {
            guard fileManager.createFile(
                atPath: currentURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                return
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: currentURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            currentFileSize += data.count
        } catch {
            // Logging must never affect application behavior.
        }
    }

    private func rollFiles() {
        let fileManager = FileManager.default
        for index in stride(from: retainedArchiveCount, through: 1, by: -1) {
            let source = archiveURL(index)
            let destination = archiveURL(index + 1)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if index == retainedArchiveCount {
                try? fileManager.removeItem(at: source)
            } else {
                try? fileManager.removeItem(at: destination)
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
        if fileManager.fileExists(atPath: currentURL.path) {
            try? fileManager.removeItem(at: archiveURL(1))
            try? fileManager.moveItem(at: currentURL, to: archiveURL(1))
        }
        currentFileSize = 0
    }

    private func archiveURL(_ index: Int) -> URL {
        directoryURL.appendingPathComponent("PRReview.\(index).log")
    }

    static func sanitized(_ value: String) -> String {
        var result = value
        let tokenPatterns = [
            "gho_[A-Za-z0-9_]+",
            "ghp_[A-Za-z0-9_]+",
            "github_pat_[A-Za-z0-9_]+",
        ]
        for pattern in tokenPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result, range: range, withTemplate: "<redacted>"
            )
        }
        let credentialPatterns = ["(?i)(authorization:\\s*)\\S+", "(?i)(token[=:]\\s*)\\S+"]
        for pattern in credentialPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result, range: range, withTemplate: "$1<redacted>"
            )
        }
        let limit = 2_000
        if result.count > limit {
            result = String(result.prefix(limit)) + "… [truncated]"
        }
        return result.replacingOccurrences(of: "\n", with: "\\n")
    }
}
