import Foundation
#if canImport(Darwin)
import Darwin
#endif

private var gOriginalTermios = termios()
private var gRawActive = false

/// C-level signal handler that restores the terminal and exits.
private func prrRestoreAndExit(_ sig: Int32) {
    if gRawActive {
        var t = gOriginalTermios
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &t)
        gRawActive = false
    }
    let bytes = Array(ANSI.restore().utf8)
    bytes.withUnsafeBufferPointer { buf in
        _ = write(STDOUT_FILENO, buf.baseAddress, buf.count)
    }
    _exit(128 + sig)
}

/// Owns the terminal: raw mode, size, output and input.
public final class Terminal {
    public private(set) var columns: Int
    public private(set) var rows: Int
    private var rawActive = false
    private var keyDecoder = KeyDecoder()

    public init() {
        let sz = Terminal.querySize()
        columns = sz.cols
        rows = sz.rows
    }

    public static var isTTY: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    public static func querySize() -> (cols: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    /// Re-queries the window size; returns true when it changed.
    @discardableResult
    public func pollSize() -> Bool {
        let sz = Terminal.querySize()
        guard sz.cols != columns || sz.rows != rows else { return false }
        columns = sz.cols
        rows = sz.rows
        return true
    }

    /// Enables raw mode, alternate screen, hidden cursor, mouse and paste modes.
    public func enterRaw() {
        guard !rawActive else { return }
        rawActive = true
        gRawActive = true
        tcgetattr(STDIN_FILENO, &gOriginalTermios)
        var raw = gOriginalTermios
        cfmakeraw(&raw)
        // VMIN=1, VTIME=0 (blocking reads; the app drives timing with poll()).
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        signal(SIGINT, prrRestoreAndExit)
        signal(SIGTERM, prrRestoreAndExit)
        signal(SIGHUP, prrRestoreAndExit)
        signal(SIGQUIT, prrRestoreAndExit)
        write(
            ANSI.altScreenOn + ANSI.cursorHide + ANSI.mouseOn + ANSI.bracketedPasteOn
        )
    }

    /// Restores the terminal to its original state.
    public func restore() {
        guard rawActive else { return }
        rawActive = false
        gRawActive = false
        write(ANSI.restore())
        var t = gOriginalTermios
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &t)
    }

    public func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    /// Reads one byte with a poll timeout in milliseconds; nil on timeout.
    private func readByte(timeoutMs: Int) -> UInt8? {
        var p = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let r = poll(&p, 1, Int32(timeoutMs))
        guard r > 0, (p.revents & Int16(POLLIN)) != 0 else { return nil }
        var b: UInt8 = 0
        return read(STDIN_FILENO, &b, 1) == 1 ? b : nil
    }

    /// Reads and decodes one key event; nil when the timeout elapses.
    public func readKey(timeoutMs: Int) -> Key? {
        if keyDecoder.hasPending {
            return keyDecoder.decode(first: nil) { [weak self] ms in
                self?.readByte(timeoutMs: ms)
            }
        }
        guard let b = readByte(timeoutMs: timeoutMs) else { return nil }
        return keyDecoder.decode(first: b) { [weak self] ms in
            self?.readByte(timeoutMs: ms)
        }
    }
}
