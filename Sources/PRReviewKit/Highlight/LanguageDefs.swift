import Foundation

/// Data-driven language definitions. Best-effort highlighting only.
public enum LanguageDefs {

    static let swift = Language(
        lineComments: ["//"],
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        stringDelims: ["\"", "'"],
        keywords: Set([
            "func", "let", "var", "if", "else", "guard", "for", "while", "repeat",
            "switch", "case", "default", "break", "continue", "return", "in", "where",
            "class", "struct", "enum", "protocol", "extension", "actor", "init", "deinit",
            "public", "private", "fileprivate", "internal", "open", "static", "final",
            "throws", "throw", "try", "catch", "do", "async", "await", "defer", "import",
            "self", "super", "nil", "true", "false", "Some", "none", "as", "is", "typealias",
            "associatedtype", "subscript", "operator", "mutating", "nonmutating", "lazy",
            "weak", "unowned", "inout", "escaping", "convenience", "override", "required",
            "indirect", "case", "precedencegroup", "get", "set", "willSet", "didSet",
        ]),
        literalKeywords: Set(["true", "false", "nil"])
    )

    static let c = Language(
        lineComments: ["//"],
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        stringDelims: ["\"", "'"],
        keywords: Set([
            "if", "else", "for", "while", "do", "switch", "case", "default", "break",
            "continue", "return", "goto", "typedef", "struct", "union", "enum", "static",
            "extern", "const", "volatile", "register", "inline", "sizeof", "void", "int",
            "char", "float", "double", "long", "short", "unsigned", "signed", "bool",
            "true", "false", "NULL", "nullptr", "class", "public", "private", "protected",
            "virtual", "override", "namespace", "using", "template", "typename", "new",
            "delete", "this", "auto", "nullptr_t", "constexpr", "operator", "friend",
        ])
    )

    static let java = Language(
        lineComments: ["//"],
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        stringDelims: ["\"", "'"],
        keywords: Set([
            "if", "else", "for", "while", "do", "switch", "case", "default", "break",
            "continue", "return", "class", "interface", "extends", "implements", "public",
            "private", "protected", "static", "final", "abstract", "void", "new", "this",
            "super", "import", "package", "try", "catch", "finally", "throw", "throws",
            "instanceof", "enum", "synchronized", "volatile", "transient", "native",
            "boolean", "int", "long", "float", "double", "char", "byte", "short",
            "true", "false", "null", "record", "var", "yield", "sealed", "permits",
        ]),
        literalKeywords: Set(["true", "false", "null"])
    )

    static let kotlin = Language(
        lineComments: ["//"],
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        stringDelims: ["\"", "'"],
        keywords: Set([
            "fun", "val", "var", "if", "else", "when", "for", "while", "do", "return",
            "class", "interface", "object", "companion", "data", "enum", "sealed", "open",
            "final", "abstract", "override", "public", "private", "internal", "protected",
            "inline", "suspend", "import", "package", "this", "super", "null", "true",
            "false", "in", "is", "as", "by", "get", "set", "constructor", "init",
            "try", "catch", "finally", "throw", "typealias", "where",
        ]),
        literalKeywords: Set(["true", "false", "null"])
    )

    static let javascript = Language(
        lineComments: ["//"],
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        stringDelims: ["\"", "'", "`"],
        keywords: Set([
            "function", "const", "let", "var", "if", "else", "for", "while", "do",
            "switch", "case", "default", "break", "continue", "return", "class", "extends",
            "new", "this", "super", "import", "export", "from", "async", "await", "yield",
            "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of",
            "delete", "void", "static", "get", "set", "arguments", "null", "undefined",
            "true", "false", "NaN", "globalThis", "with", "debugger",
        ]),
        literalKeywords: Set(["true", "false", "null", "undefined"])
    )

    static let typescript = Language(
        lineComments: ["//"],
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        stringDelims: ["\"", "'", "`"],
        keywords: Set([
            "function", "const", "let", "var", "if", "else", "for", "while", "do",
            "switch", "case", "default", "break", "continue", "return", "class", "extends",
            "implements", "interface", "type", "new", "this", "super", "import", "export",
            "from", "async", "await", "yield", "try", "catch", "finally", "throw",
            "typeof", "instanceof", "in", "of", "delete", "void", "static", "get", "set",
            "null", "undefined", "true", "false", "readonly", "keyof", "infer", "namespace",
            "declare", "abstract", "public", "private", "protected", "enum", "as", "is",
        ]),
        literalKeywords: Set(["true", "false", "null", "undefined"])
    )

    static let python = Language(
        lineComments: ["#"],
        stringDelims: ["\"", "'"],
        keywords: Set([
            "def", "class", "if", "elif", "else", "for", "while", "return", "import",
            "from", "as", "with", "try", "except", "finally", "raise", "pass", "break",
            "continue", "lambda", "yield", "global", "nonlocal", "del", "assert", "async",
            "await", "in", "is", "not", "and", "or", "None", "True", "False", "self",
            "match", "case", "print",
        ]),
        literalKeywords: Set(["None", "True", "False"])
    )

    static let ruby = Language(
        lineComments: ["#"],
        stringDelims: ["\"", "'"],
        keywords: Set([
            "def", "class", "module", "if", "elsif", "else", "unless", "for", "while",
            "until", "do", "return", "require", "end", "then", "case", "when", "break",
            "next", "redo", "retry", "yield", "super", "self", "nil", "true", "false",
            "begin", "rescue", "ensure", "raise", "and", "or", "not", "in", "lambda",
            "proc", "attr_accessor", "include", "extend", "prepend",
        ]),
        literalKeywords: Set(["true", "false", "nil"])
    )

    static let go = Language(
        lineComments: ["//"],
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        stringDelims: ["\"", "'", "`"],
        keywords: Set([
            "func", "package", "import", "var", "const", "type", "struct", "interface",
            "map", "chan", "if", "else", "for", "range", "switch", "case", "default",
            "break", "continue", "return", "go", "defer", "select", "fallthrough", "goto",
            "nil", "true", "false", "iota", "make", "new", "append", "len", "cap",
            "panic", "recover", "error", "string", "int", "float64", "bool", "byte",
        ]),
        literalKeywords: Set(["true", "false", "nil"])
    )

    static let rust = Language(
        lineComments: ["//"],
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        stringDelims: ["\"", "'"],
        keywords: Set([
            "fn", "let", "mut", "const", "static", "if", "else", "match", "for", "while",
            "loop", "return", "break", "continue", "struct", "enum", "impl", "trait",
            "pub", "crate", "mod", "use", "where", "async", "await", "move", "ref",
            "self", "super", "in", "type", "dyn", "unsafe", "extern", "true", "false",
            "Some", "None", "Ok", "Err", "as", "async", "try",
        ]),
        literalKeywords: Set(["true", "false"])
    )

    static let shell = Language(
        lineComments: ["#"],
        stringDelims: ["\"", "'"],
        keywords: Set([
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
            "case", "esac", "function", "return", "exit", "export", "local", "readonly",
            "shift", "source", "set", "unset", "echo", "printf", "cd", "eval", "exec",
            "trap", "test", "true", "false",
        ])
    )

    static let json = Language(
        stringDelims: ["\""],
        keywords: Set([]),
        literalKeywords: Set(["true", "false", "null"])
    )

    static let yaml = Language(
        lineComments: ["#"],
        stringDelims: ["\"", "'"],
        keywords: Set([]),
        literalKeywords: Set(["true", "false", "null", "yes", "no", "on", "off"]),
        colonKeys: true
    )

    static let toml = Language(
        lineComments: ["#"],
        stringDelims: ["\"", "'"],
        keywords: Set([]),
        literalKeywords: Set(["true", "false"]),
        colonKeys: false
    )

    static let sql = Language(
        lineComments: ["--"],
        blockCommentStart: "/*",
        blockCommentEnd: "*/",
        stringDelims: ["\"", "'"],
        keywords: Set([
            "select", "from", "where", "insert", "into", "values", "update", "set",
            "delete", "create", "table", "index", "view", "alter", "drop", "join",
            "inner", "left", "right", "full", "outer", "on", "group", "by", "order",
            "having", "limit", "offset", "union", "all", "distinct", "as", "and", "or",
            "not", "null", "is", "in", "like", "between", "exists", "case", "when",
            "then", "else", "end", "primary", "key", "foreign", "references", "default",
            "constraint", "unique", "check", "procedure", "begin", "commit", "rollback",
        ]),
        literalKeywords: Set(["true", "false", "null"])
    )

    static let html = Language(
        lineComments: [],
        blockCommentStart: "<!--",
        blockCommentEnd: "-->",
        stringDelims: ["\"", "'"],
        keywords: Set([])
    )

    private static let table: [(extensions: [String], language: Language)] = [
        (["swift"], swift),
        (["c", "h", "m", "mm"], c),
        (["cpp", "cc", "cxx", "hpp", "hh", "hxx"], c),
        (["java"], java),
        (["kt", "kts"], kotlin),
        (["js", "jsx", "mjs", "cjs"], javascript),
        (["ts", "tsx", "mts"], typescript),
        (["py", "pyi"], python),
        (["rb", "rake", "gemspec"], ruby),
        (["go"], go),
        (["rs"], rust),
        (["sh", "bash", "zsh", "fish", "zshrc", "bashrc"], shell),
        (["json"], json),
        (["yml", "yaml"], yaml),
        (["toml"], toml),
        (["sql"], sql),
        (["html", "htm", "xml", "svg"], html),
    ]

    public static func language(for path: String) -> Language? {
        languageID(for: path).flatMap { language(forID: $0) }
    }

    /// The table index of the language for a path, or nil. Compact identity:
    /// hashing/equating an `Int?` is far cheaper than a full `Language` (which
    /// carries keyword sets), so rendered-line cache keys use this instead.
    public static func languageID(for path: String) -> Int? {
        let ext = (path as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            for (i, entry) in table.enumerated() where entry.extensions.contains(ext) {
                return i
            }
        }
        // dotfiles like .bashrc / .zshrc
        let base = (path as NSString).lastPathComponent.lowercased()
        for (i, entry) in table.enumerated() where entry.extensions.contains(base) {
            return i
        }
        return nil
    }

    public static func language(forID id: Int?) -> Language? {
        guard let id, id >= 0, id < table.count else { return nil }
        return table[id].language
    }
}
