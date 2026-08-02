import Foundation

/// Writes text to the system clipboard. Abstracted so tests can capture the
/// exact text without spawning `pbcopy`.
public protocol ClipboardWriting {
    func write(_ text: String) throws
}

/// Production implementation: pipes the text to `/usr/bin/pbcopy`.
public struct SystemClipboard: ClipboardWriting {

    public init() {}

    public func write(_ text: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        proc.standardInput = pipe
        try proc.run()
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        proc.waitUntilExit()
    }
}
