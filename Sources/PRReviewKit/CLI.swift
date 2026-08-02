import Foundation

public enum PRReviewCLI {

    public static let version = "1.0.0"

    public static func run(_ args: [String]) -> Int32 {
        var demo = false
        var dump: (cols: Int, rows: Int)?
        var ref: String?

        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--demo":
                demo = true
            case "--dump":
                if i + 1 < args.count, let wh = parseSize(args[i + 1]) {
                    dump = wh
                    i += 1
                } else {
                    dump = (100, 32)
                }
            case "--help", "-h":
                print(usage)
                return 0
            case "--version", "-V":
                print("pr-review \(version)")
                return 0
            default:
                if a.hasPrefix("-") {
                    fputs("Unknown option: \(a)\n", stderr)
                    fputs(usage + "\n", stderr)
                    return 2
                }
                ref = a
            }
            i += 1
        }

        if !demo && ref == nil {
            fputs("Missing PR reference.\n\n" + usage + "\n", stderr)
            return 2
        }

        // ---- Build the model -------------------------------------------------
        var model: AppModel
        var client: GitHubClient?
        if demo {
            model = DemoData.makeDemoModel()
        } else {
            do {
                let c = GitHubClient()
                try GH.ensureGH()
                fputs("Resolving PR reference…\n", stderr)
                let ep = try c.resolveEndpoint(from: ref!)
                fputs("Fetching PR \(ep)…\n", stderr)
                let pr = try c.fetchPRInfo(ep)
                fputs("Fetching diff…\n", stderr)
                let files = try c.fetchDiff(ep)
                fputs("Fetching review threads…\n", stderr)
                let threads = try c.fetchThreads(ep)
                let drafts = DraftStore.loadDrafts(ep, sha: pr.headRefOid)
                let viewed = DraftStore.loadViewed(ep, sha: pr.headRefOid)
                model = AppModel()
                model.endpoint = ep
                model.pr = pr
                model.headOID = pr.headRefOid
                model.files = files
                model.threads = threads
                model.drafts = drafts
                model.viewed = viewed
                model.rebuildRows()
                model.loaded = true
                client = c
            } catch {
                fputs("Error: \(error)\n", stderr)
                return 1
            }
        }

        // ---- --dump: render one frame headlessly ------------------------------
        if let dump {
            let w = max(20, dump.cols)
            let h = max(10, dump.rows)
            let screen = Screen(width: w, height: h)
            AppView.render(model: model, into: screen)
            print(screen.debugDump())
            return 0
        }

        // ---- TUI loop ---------------------------------------------------------
        guard Terminal.isTTY else {
            fputs("pr-review requires an interactive terminal.\n", stderr)
            fputs("Tip: use `--demo --dump 100x32` to preview a frame without a TTY.\n", stderr)
            return 1
        }

        let controller = AppController(model: model, client: client)
        model.setMessage("Welcome — press ? for help. Drafts are saved automatically.", duration: 8)

        let term = Terminal()
        term.enterRaw()
        defer { term.restore() }
        let screen = Screen(width: term.columns, height: term.rows)

        func draw() {
            AppView.render(model: model, into: screen)
            screen.render(to: term)
        }

        draw()
        while !model.shouldQuit {
            if term.pollSize() {
                screen.resize(term.columns, term.rows)
                draw()
            }
            if let key = term.readKey(timeoutMs: 40) {
                controller.handle(key, screenW: term.columns, screenH: term.rows)
                controller.drainPending()
                draw()
            } else {
                controller.drainPending()
                if model.dirty {
                    draw()
                }
            }
        }
        return 0
    }

    static func parseSize(_ s: String) -> (cols: Int, rows: Int)? {
        let parts = s.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }

    static let usage = """
    pr-review \(version) — terminal UI for reviewing GitHub pull requests

    Usage:
      pr-review [options] <pr-ref>
      pr-review [options] --demo

    PR references:
      https://github.com/owner/repo/pull/123
      owner/repo#123
      123                      (resolved against the current repository)

    Options:
      --demo            Use a built-in sample PR (no network)
      --dump [WxH]      Render one frame as plain text and exit (no TTY needed)
      --help, -h        Show this help
      --version, -V     Show version

    Requirements:
      macOS 13+, Swift 5.9+, and the GitHub CLI (`gh`) installed and
      authenticated (`gh auth login`). No Xcode GUI required; build with:
        swift build -c release
    """
}
