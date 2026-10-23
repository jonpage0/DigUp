import AppKit
import DigUpKit
import SwiftUI

/// How an AI app is told about DigUp: its own standard way to add a local (stdio) MCP server that runs DigUp's helper
/// (`digup mcp`). DigUp shows it to copy and never writes an app's settings itself.
struct AIClientSetup: Identifiable, Equatable {
    let app: String
    /// Where it goes: a command to run in Terminal, or an entry for a file of the app's.
    let place: String
    let text: String
    var id: String { app }

    /// What the AI app runs: the helper in this app's bundle.
    static var helper: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/digup").path
    }

    /// The helper's arguments: the settings it reads when they aren't the app's own (a dev run's `-defaultsSuite`),
    /// and the index when it isn't the default one.
    static func arguments(suite: String?, index: URL) -> [String] {
        var arguments = ["mcp"]
        if let suite { arguments += ["--defaults-suite", suite] }
        if index.standardizedFileURL != AppSettings.defaultIndexDirectory.standardizedFileURL {
            arguments += ["--index", index.path]
        }
        return arguments
    }

    /// The name each app lists DigUp under.
    static let name = "digup"

    /// Claude Code, Codex, Cursor, VS Code and Claude Desktop, each its own way (2026-10: VS Code's key is `servers`,
    /// with the transport said; the others' is `mcpServers`).
    static func all(helper: String, arguments: [String]) -> [AIClientSetup] {
        let command = ([helper] + arguments).map(shellQuoted).joined(separator: " ")
        let entry: [String: Any] = ["command": helper, "args": arguments]
        return [
            AIClientSetup(app: "Claude Code", place: "Run in Terminal:",
                          text: "claude mcp add --scope user \(name) -- \(command)"),
            AIClientSetup(app: "Codex", place: "Run in Terminal:", text: "codex mcp add \(name) -- \(command)"),
            AIClientSetup(app: "Cursor", place: "Add to ~/.cursor/mcp.json:",
                          text: json(["mcpServers": [name: entry]])),
            AIClientSetup(app: "VS Code", place: "Add to its mcp.json (MCP: Open User Configuration):",
                          text: json(["servers": [name: entry.merging(["type": "stdio"]) { $1 }]])),
            AIClientSetup(app: "Claude Desktop",
                          place: "Add to ~/Library/Application Support/Claude/claude_desktop_config.json:",
                          text: json(["mcpServers": [name: entry]])),
        ]
    }

    /// A word as a shell reads it: quoted when it has anything but letters, digits and `/._-`.
    static func shellQuoted(_ word: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
        guard !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) else {
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return word
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// AI apps: whether AI apps may search through DigUp and what they may see (`AIAccess`, which `digup mcp` reads at
/// every call), their last calls, and how to add DigUp to each app.
struct AIAppsSettings: View {
    @Bindable var state: SettingsState

    /// How often the last calls are read again while the tab shows: an AI app may be calling now.
    private static let callsRefresh = Duration.seconds(3)

    private var access: AIAccess { state.model.settings.aiAccess }

    private var setups: [AIClientSetup] {
        AIClientSetup.all(helper: AIClientSetup.helper,
                          arguments: AIClientSetup.arguments(suite: AppSettings.suite,
                                                             index: state.model.settings.indexDirectory))
    }

    private func binding(_ keyPath: WritableKeyPath<AIAccess, Bool>) -> Binding<Bool> {
        Binding(get: { access[keyPath: keyPath] }, set: { on in
            var changed = access
            changed[keyPath: keyPath] = on
            state.app.setAIAccess(changed)
        })
    }

    var body: some View {
        Form {
            Section {
                toggle(\.on, "Let AI apps search your files with DigUp",
                       detail: "Apps such as Claude, Codex and Cursor can then search the way DigUp's window does and "
                        + "read the words DigUp found in a file. What they read goes to the app's AI provider. DigUp "
                        + "never changes, moves or opens a file for them.")
            }
            Section {
                toggle(\.photos, "Photos libraries",
                       detail: "Pictures and videos in your Photos libraries, with what Photos knows: people, places, "
                        + "albums.")
                if state.model.settings.includeHiddenPhotos {
                    toggle(\.hiddenPhotos, "What's hidden in Photos",
                           detail: "Its Hidden album, which DigUp indexes because you turned it on in Photos.")
                        .disabled(!access.photos)
                }
                toggle(\.code, "Code", detail: "Code search's folders.")
                toggle(\.pictures, "Pictures themselves",
                       detail: "A small picture of a result (at most \(AIAccess.picturePixels) pixels) for apps "
                        + "that can look at one. It goes to the app's AI provider too.")
                toggle(\.sensitive, "Pictures rated sensitive",
                       detail: "Pictures and videos the detector rates sensitive, at Blur sensitive pictures' "
                        + "position (General; Revealing while it's off), and the ones it hasn't rated yet. Off, AI apps "
                        + "never see them.")
            } header: {
                Text("What they may see")
            } footer: {
                footnote("Everything else they can search: the folders you chose. Each change applies to their next "
                         + "call.")
            }
            .disabled(!access.on)
            Section {
                ForEach(setups) { SetupRow(setup: $0) }
            } header: {
                Text("Add DigUp to an AI app")
            } footer: {
                footnote("DigUp doesn't change any app's settings: run the command or add the entry yourself. The app "
                         + "asks before it uses DigUp, as you set it up there.")
            }
            Section {
                if state.aiCalls.isEmpty {
                    Text("No AI app has searched yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(state.aiCalls.reversed().enumerated()), id: \.offset) { _, call in
                        CallRow(call: call)
                    }
                }
            } header: {
                Text("Last calls")
            } footer: {
                footnote("Which app, which tool and how many results; never what was searched for.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .task {
            while !Task.isCancelled {
                state.refreshAICalls()
                try? await Task.sleep(for: Self.callsRefresh)
            }
        }
    }

    private func toggle(_ keyPath: WritableKeyPath<AIAccess, Bool>, _ title: String, detail: String) -> some View {
        Toggle(isOn: binding(keyPath)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One call: when, which app, which tool, and what came of it.
private struct CallRow: View {
    let call: AICall

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(call.time.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(call.client)
                .lineLimit(1)
            Text(call.tool)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let refused = call.refused {
                Text("Refused: \(refused)")
                    .foregroundStyle(.orange)
            } else {
                Text(call.results == 1 ? "1 result" : "\(call.results) results")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
    }
}

/// An app's way to add DigUp, to copy.
private struct SetupRow: View {
    let setup: AIClientSetup
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(setup.app)
                    .fontWeight(.medium)
                Text(setup.place)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(setup.text, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            Text(setup.text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
        }
        .padding(.vertical, 2)
    }
}
