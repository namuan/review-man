import Foundation

public enum TokenKind: Equatable {
    case plain
    case keyword
    case string
    case comment
    case number
    case type
    case directive
}

public struct CodeToken: Equatable {
    public var range: Range<Int>
    public var kind: TokenKind
}

public struct Language {
    public var lineComments: [String]
    public var blockCommentStart: String?
    public var blockCommentEnd: String?
    public var stringDelims: [Character]
    public var keywords: Set<String>
    public var literalKeywords: Set<String> = []
    /// Identifiers immediately followed by `:` are highlighted as types (YAML/TOML keys).
    public var colonKeys: Bool = false

    public init(
        lineComments: [String] = [],
        blockCommentStart: String? = nil,
        blockCommentEnd: String? = nil,
        stringDelims: [Character] = ["\"", "'"],
        keywords: Set<String> = [],
        literalKeywords: Set<String> = [],
        colonKeys: Bool = false
    ) {
        self.lineComments = lineComments
        self.blockCommentStart = blockCommentStart
        self.blockCommentEnd = blockCommentEnd
        self.stringDelims = stringDelims
        self.keywords = keywords
        self.literalKeywords = literalKeywords
        self.colonKeys = colonKeys
    }
}

/// Best-effort, line-oriented tokenizer. Comments and strings are found first;
/// keywords/numbers/types are matched in the remaining code spans.
public enum Highlighter {

    public static func language(for path: String) -> Language? {
        LanguageDefs.language(for: path)
    }

    public static func tokenize(_ line: String, _ lang: Language?) -> [CodeToken] {
        guard let lang, !line.isEmpty else { return [] }
        let chars = Array(line)
        let n = chars.count
        var tokens: [CodeToken] = []
        var i = 0

        while i < n {
            let c = chars[i]

            // Line comment
            if lang.lineComments.contains(where: { matchPrefix(chars, i, $0) }) {
                tokens.append(CodeToken(range: i..<n, kind: .comment))
                break
            }

            // Block comment (single-line occurrences)
            if let bs = lang.blockCommentStart, matchPrefix(chars, i, bs) {
                let be = lang.blockCommentEnd ?? "*/"
                var j = i + bs.count
                while j < n, !matchPrefix(chars, j, be) { j += 1 }
                j = min(n, j + be.count)
                tokens.append(CodeToken(range: i..<j, kind: .comment))
                i = j
                continue
            }

            // String literal
            if lang.stringDelims.contains(c) {
                var j = i + 1
                while j < n {
                    if chars[j] == "\\" {
                        j += 2
                        continue
                    }
                    if chars[j] == c {
                        j += 1
                        break
                    }
                    j += 1
                }
                tokens.append(CodeToken(range: i..<min(j, n), kind: .string))
                i = min(j, n)
                continue
            }

            // Preprocessor directive (#import, #include, etc.)
            if c == "#", !lang.lineComments.contains("#") {
                var j = i + 1
                while j < n, chars[j].isLetter { j += 1 }
                let word = String(chars[i..<j])
                if lang.directives.contains(word) {
                    tokens.append(CodeToken(range: i..<j, kind: .directive))
                    i = j
                    continue
                }
            }

            // Number
            if c.isNumber {
                var j = i
                while j < n, isNumberChar(chars[j]) { j += 1 }
                tokens.append(CodeToken(range: i..<j, kind: .number))
                i = j
                continue
            }

            // Identifier / keyword / type
            if c.isLetter || c == "_" || c == "@" || c == "$" {
                var j = i
                while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                var kind: TokenKind = .plain
                if lang.keywords.contains(word) {
                    kind = .keyword
                } else if lang.literalKeywords.contains(word) {
                    kind = .keyword
                } else if word.first?.isUppercase == true {
                    kind = .type
                } else if lang.colonKeys, j < n, chars[j] == ":" {
                    kind = .type
                }
                if kind != .plain {
                    tokens.append(CodeToken(range: i..<j, kind: kind))
                }
                i = j
                continue
            }

            i += 1
        }
        return tokens
    }

    private static func isNumberChar(_ c: Character) -> Bool {
        c.isNumber || c == "." || c == "_" || c == "x" || c == "X" || c == "o" || c == "b"
    }

    static func matchPrefix(_ chars: [Character], _ i: Int, _ s: String) -> Bool {
        let sc = Array(s)
        guard i + sc.count <= chars.count else { return false }
        for k in 0..<sc.count where chars[i + k] != sc[k] {
            return false
        }
        return true
    }
}

public extension Language {
    /// Preprocessor directive words (Swift/ObjC/C).
    var directives: Set<String> {
        ["import", "include", "define", "ifdef", "ifndef", "pragma", "else", "endif", "if"]
    }
}
