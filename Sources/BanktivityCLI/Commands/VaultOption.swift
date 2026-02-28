// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser

enum OutputFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
    case json
    case compact
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Path to .bank8 vault (or set BANKTIVITY_FILE_PATH)")
    var vault: String?

    @Option(name: .long, help: "Output format: json (pretty-printed) or compact (single-line)")
    var format: OutputFormat = .json
}
