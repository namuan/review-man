import Foundation

/// A decoded input event from the terminal.
public enum Key: Equatable {
    case char(Character)
    case enter
    case tab
    case backtab
    case backspace
    case delete
    case escape
    case up, down, left, right
    case home, end
    case pageUp, pageDown
    case ctrl(Character)
    case paste(String)
    case mouseWheelUp(col: Int, row: Int)
    case mouseWheelDown(col: Int, row: Int)
    case mouseDown(button: Int, col: Int, row: Int)
    case unknown
}

/// Byte-stream -> Key decoder (ANSI escape sequences, SGR mouse, bracketed
/// paste and UTF-8). Stateless: each `decode` call consumes one key event,
/// using the `next` closure for any follow-up bytes it needs.
public struct KeyDecoder {
    /// A byte that followed an ESC and is delivered on the next decode call,
    /// so "Esc then key pressed quickly" behaves like two separate keys.
    private var pendingByte: UInt8?

    public var hasPending: Bool { pendingByte != nil }

    public init() {}

    /// `first` is nil when a pending byte should be delivered without reading
    /// a new byte from the stream (see `Terminal.readKey`).
    public mutating func decode(first: UInt8?, next: (Int) -> UInt8?) -> Key {
        if let pb = pendingByte {
            pendingByte = nil
            return decode(first: pb, next: next)
        }
        guard let first else { return .unknown }
        switch first {
        case 0x0D, 0x0A:
            return .enter
        case 0x09:
            return .tab
        case 0x7F, 0x08:
            return .backspace
        case 0x1B:
            return decodeEscape(next)
        case 0x01...0x1A:
            let c = Character(UnicodeScalar(96 + Int(first))!)
            return .ctrl(c)
        default:
            if first < 0x80 {
                return .char(Character(UnicodeScalar(first)))
            }
            return decodeUTF8(first: first, next: next)
        }
    }

    private func decodeUTF8(first: UInt8, next: (Int) -> UInt8?) -> Key {
        var bytes: [UInt8] = [first]
        let needed: Int
        if first & 0xE0 == 0xC0 {
            needed = 1
        } else if first & 0xF0 == 0xE0 {
            needed = 2
        } else if first & 0xF8 == 0xF0 {
            needed = 3
        } else {
            return .unknown
        }
        for _ in 0..<needed {
            guard let b = next(20) else { return .unknown }
            bytes.append(b)
        }
        guard let s = String(bytes: bytes, encoding: .utf8), let ch = s.first else {
            return .unknown
        }
        return .char(ch)
    }

    private mutating func decodeEscape(_ next: (Int) -> UInt8?) -> Key {
        guard let b = next(25) else { return .escape }
        switch b {
        case UInt8(ascii: "["):
            return decodeCSI(next)
        case UInt8(ascii: "O"):
            guard let f = next(25) else { return .unknown }
            switch f {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            case UInt8(ascii: "C"): return .right
            case UInt8(ascii: "D"): return .left
            case UInt8(ascii: "H"): return .home
            case UInt8(ascii: "F"): return .end
            default: return .unknown
            }
        default:
            // Alt+key or a fast "Esc then key": deliver Esc now and re-deliver
            // the byte on the next call so no keystroke is lost.
            pendingByte = b
            return .escape
        }
    }

    private func decodeCSI(_ next: (Int) -> UInt8?) -> Key {
        var params = ""
        while true {
            guard let b = next(25) else { return .unknown }
            if b >= 0x40 && b <= 0x7E {
                return csiFinal(params: params, final: b, next: next)
            }
            params.append(Character(UnicodeScalar(b)))
            if params.count > 32 { return .unknown }
        }
    }

    private func csiFinal(params: String, final: UInt8, next: (Int) -> UInt8?) -> Key {
        // Bracketed paste start: consume until ESC[201~ terminator.
        if params == "200", final == UInt8(ascii: "~") {
            var bytes: [UInt8] = []
            let terminator = Array("\u{1b}[201~".utf8)
            while true {
                guard let b = next(25) else { break } // aborted paste
                bytes.append(b)
                if bytes.count > 1_000_000 { break }
                if bytes.suffix(terminator.count) == terminator {
                    bytes.removeLast(terminator.count)
                    break
                }
            }
            return .paste(String(bytes: bytes, encoding: .utf8) ?? "")
        }
        let cleaned = params.hasPrefix("<") ? String(params.dropFirst()) : params
        let isSGR = params.hasPrefix("<")
        let parts = cleaned.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        switch final {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "Z"): return .backtab
        case UInt8(ascii: "~"):
            switch parts.first ?? 0 {
            case 1, 7: return .home
            case 4, 8: return .end
            case 3: return .delete
            case 5: return .pageUp
            case 6: return .pageDown
            default: return .unknown
            }
        case UInt8(ascii: "M"), UInt8(ascii: "m"):
            guard isSGR, parts.count >= 3 else { return .unknown }
            let b = parts[0], x = parts[1], y = parts[2]
            let pressed = final == UInt8(ascii: "M")
            if b & 64 != 0 {
                return (b & 1 == 0)
                    ? .mouseWheelUp(col: x, row: y)
                    : .mouseWheelDown(col: x, row: y)
            }
            if pressed {
                return .mouseDown(button: b & 3, col: x, row: y)
            }
            return .unknown
        default:
            return .unknown
        }
    }
}
