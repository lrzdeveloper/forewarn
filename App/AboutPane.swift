import SwiftUI

/// Settings › About: who makes Forewarn, under which license, on whose work, and what changed. The last pane, as in
/// the settings of open-source Mac apps; an LSUIElement app has no app menu to hold an About item.
struct AboutPane: View {
    @State private var shown: AboutDocument?

    private static let repository = URL(string: "https://github.com/lrzdeveloper/forewarn")!
    private static let models = URL.applicationSupportDirectory.appending(path: "Forewarn/Models")

    /// The weights are not bundled : they are acknowledged only on a Mac where `make model` put them.
    private var timestralInstalled: Bool {
        FileManager.default
            .fileExists(atPath: Self.models.appending(path: "Timestral-5M-core-32768-fp32.mlmodelc").path)
    }

    var body: some View {
        Form {
            Section {
                header
            }
            Section {
                LabeledContent("Developer") {
                    Link(destination: URL(string: "https://github.com/lrzdeveloper")!) {
                        Text(verbatim: "Luca De Rosa")
                    }
                }
                row("Source code", detail: "Forewarn is open source.") {
                    Link("View on GitHub", destination: Self.repository)
                }
                row("Problems and ideas", detail: "Report them on GitHub, with your macOS version.") {
                    Link("Report an Issue", destination: Self.repository.appending(path: "issues/new"))
                }
                row("Privacy", detail: "Everything stays on this Mac: no account, no analytics, no connections.") {
                    Link("Read More", destination: URL(string: "https://github.com/lrzdeveloper/forewarn#privacy")!)
                }
            }
            Section {
                row("Release notes", detail: "What changed in each version.") {
                    Button("What's New…") { shown = .changelog }
                        .accessibilityIdentifier("whatsNew")
                }
            }
            Section {
                license("Forewarn", by: "Luca De Rosa", license: "Apache License 2.0", .forewarn)
                license("GRDB.swift", by: "Gwendal Roué", license: "MIT License", .grdb)
                if timestralInstalled {
                    license("Timestral-5M", by: "Mistral AI", license: "Modified MIT License", .timestral)
                }
            } header: {
                Text("License and acknowledgements")
            } footer: {
                Text("Forewarn is built on these and Apple's frameworks.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $shown) { DocumentSheet(document: $0) }
    }

    /// The app introduces itself with its icon: the one place in Settings the full-colour mark appears.
    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Forewarn")
                    .font(.title2.weight(.semibold))
                Text("Version \(Self.version) (\(Self.build))")
                    .foregroundStyle(.subdued)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("aboutVersion")
            }
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    private static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    private func row(
        _ title: LocalizedStringKey, detail: LocalizedStringKey, @ViewBuilder action: () -> some View
    ) -> some View {
        LabeledContent {
            action()
        } label: {
            Text(title)
            Text(detail)
        }
    }

    /// Names, authors and license names are proper names: never translated.
    private func license(_ name: String, by author: String, license: String, _ document: AboutDocument) -> some View {
        LabeledContent {
            Button("View License…") { shown = document }
                .accessibilityIdentifier("license-\(document.rawValue)")
        } label: {
            Text(verbatim: "\(name) · \(author)")
            Text(verbatim: license)
        }
    }
}

/// A text the app ships (or `make model` installs), shown as written: legal texts and release notes stay in English.
enum AboutDocument: String, Identifiable {
    case changelog, forewarn, grdb, timestral
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .changelog: "What's New in Forewarn"
        case .forewarn: "Forewarn License"
        case .grdb: "GRDB.swift License"
        case .timestral: "Timestral-5M License"
        }
    }

    var text: String {
        let url: URL? = switch self {
        case .changelog: Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
        case .forewarn: Bundle.main.url(forResource: "LICENSE", withExtension: nil)
        case .grdb: Bundle.main.url(forResource: "GRDB.swift", withExtension: "txt")
        case .timestral: URL.applicationSupportDirectory.appending(path: "Forewarn/Models/Timestral-5M-LICENSE.txt")
        }
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            // A model installed before `make model` fetched its license; reinstalling adds it.
            ?? "https://huggingface.co/mistralai/Timestral-5M/blob/main/LICENSE"
    }
}

/// The text in a sheet over Settings, with Done (Return or Esc).
private struct DocumentSheet: View {
    let document: AboutDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Title and Done as bars: no fixed rules, the system's scroll edge shows only while text runs under one.
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if document == .changelog {
                    Markdown(text: document.text)
                } else {
                    Text(verbatim: document.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        }
        .accessibilityIdentifier("documentText")
        .safeAreaBar(edge: .top) {
            Text(document.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .safeAreaBar(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("documentDone")
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
        .onExitCommand { dismiss() } // Esc, as Done is Return
    }
}

/// Just enough Markdown for CHANGELOG.md: headings and bullets by line, emphasis inline.
private struct Markdown: View {
    let text: String

    /// Wrapped lines joined back to their bullet or paragraph.
    private var lines: [String] {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let last = lines.last, !last.isEmpty, !last.hasPrefix("#"), !line.isEmpty, !line.hasPrefix("#"),
               !line.hasPrefix("- ")
            {
                lines[lines.count - 1] += " " + line
            } else {
                lines.append(line)
            }
        }
        // From the first version on: the file's own introduction is about the file.
        return Array(lines.filter { !$0.isEmpty }.drop { !$0.hasPrefix("## ") })
    }

    var body: some View {
        // By position: the text is a fixed file, and lines can repeat.
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            if line.hasPrefix("## ") {
                Text(inline(line.dropFirst(3))).font(.title3.weight(.semibold)).padding(.top, 8)
            } else if line.hasPrefix("### ") {
                Text(inline(line.dropFirst(4))).font(.headline).padding(.top, 4)
            } else if line.hasPrefix("- ") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "•").accessibilityHidden(true)
                    Text(inline(line.dropFirst(2)))
                }
            } else {
                Text(inline(line))
            }
        }
    }

    /// Emphasis kept, links dropped: the URLs point into the repository, which the About pane already links.
    private func inline(_ line: some StringProtocol) -> AttributedString {
        var text = (try? AttributedString(markdown: String(line))) ?? AttributedString(String(line))
        text.link = nil
        return text
    }
}
