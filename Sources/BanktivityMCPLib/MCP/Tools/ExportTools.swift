// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import BanktivityLib
import MCP

func registerExportTools(registry: ToolRegistry, container: NSPersistentContainer, bankFilePath: String) {
    registry.register(
        name: "export_turtle",
        access: .read,
        description: "Export the entire vault as RDF/Turtle (.ttl). Returns the Turtle content as text, or writes to a file if output_path is provided.",
        inputSchema: ToolHelpers.schema(properties: [
            "output_path": ToolHelpers.property(
                type: "string",
                description: "Optional file path to write the .ttl output to. If omitted, returns the Turtle content directly."
            ),
        ])
    ) { arguments in
        let turtle = try VaultExporter.exportTurtle(container: container, bankFilePath: bankFilePath)

        if let outputPath = ToolHelpers.getString(arguments, key: "output_path") {
            try turtle.write(toFile: outputPath, atomically: true, encoding: .utf8)
            return ToolHelpers.successResponse("Exported to \(outputPath)")
        }

        return CallTool.Result(content: [.text(turtle)])
    }
}
