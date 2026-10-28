import SwiftUI

/// What the popover shows: the overview, or one feature in detail in its place (HIG, Popovers: one popover, resized
/// with an animation, nothing on top of it). The way Control Center opens a module.
enum PopoverPage: Hashable {
    case overview, health, disk
}

/// A page that replaces the overview: back to it at the top (also Esc), the title, then modules. Scrolls when it is
/// taller than the screen allows a popover to be.
struct DetailPage<Content: View>: View {
    let title: LocalizedStringKey
    let onBack: () -> Void
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 400
    /// The panel's own screen, read again when the panel moves to another screen or the screen changes (a display
    /// arranged, the Dock shown): the main screen can be another display entirely.
    @State private var window: NSWindow?
    @State private var screenHeight = NSScreen.main?.visibleFrame.height ?? 800
    /// Room for the menu bar, the header above the scroll view and the panel's padding.
    private var maxHeight: CGFloat { screenHeight - 120 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    Button(action: onBack) {
                        Label("Forewarn", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .help("Back")
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("back")
                    Spacer()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // As tall as the content while the screen allows, leaving room for the menu bar and the header.
            .frame(height: min(contentHeight, maxHeight))
            .scrollBounceBehavior(.basedOnSize)
            // No bars float over this content: the edge fade only dimmed the last lines (Xcode's contrast audit).
            .scrollEdgeEffectHidden()
        }
        .background(HostingWindowReader(window: $window).accessibilityHidden(true))
        .onChange(of: window) { readScreen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { note in
            if note.object as? NSWindow == window {
                readScreen()
            }
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            readScreen()
        }
    }

    private func readScreen() {
        if let height = (window?.screen ?? NSScreen.main)?.visibleFrame.height {
            screenHeight = height
        }
    }
}

/// One card of a detail page, in the manner of Weather's and Health's modules: a symbol and a name, then the value
/// and what it means.
struct Module<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.subdued)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .card()
    }
}

/// The large figure at the top of a module.
struct ModuleValue: View {
    let text: String

    var body: some View {
        Text(text).figure(.largeTitle)
    }
}

extension View {
    /// Forewarn's one card, in the popover, its pages and the welcome window: a quinary fill, corner radius 12,
    /// 12 points inside. A card with a name puts it in a `Module` header.
    func card(padding: CGFloat = 12, fill: AnyShapeStyle = AnyShapeStyle(.quinary)) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Forewarn's answers and figures: semibold SF Pro Rounded with even digits, in two sizes only. Large title for
    /// the one answer of a screen or module (the popover headline, a module's value), title 3 for the figures that
    /// back it (stat strips, cycles). Everything else, Settings and the welcome window included, is plain SF Pro.
    func figure(_ style: Font.TextStyle) -> some View {
        font(.system(style, design: .rounded, weight: .semibold)).monospacedDigit()
    }
}
