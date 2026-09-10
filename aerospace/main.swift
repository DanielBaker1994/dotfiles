import AppKit
import Foundation

// Entry point (must be in main.swift for multi-file builds).

let cliArgs = CommandLine.arguments
if cliArgs.count > 1 && cliArgs[1] == "toggle" {
    exit(sendToggle(name: "workspace-switcher") ? 0 : 1)
}
let showOnLaunch = cliArgs.count > 1 && cliArgs[1] == "show"

let app = NSApplication.shared
let delegate = AppDelegate(showOnLaunch: showOnLaunch)
app.delegate = delegate
app.run()