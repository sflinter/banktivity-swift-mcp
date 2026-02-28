// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser

struct VaultOption: ParsableArguments {
    @Option(name: .long, help: "Path to .bank8 vault (or set BANKTIVITY_FILE_PATH)")
    var vault: String?
}
