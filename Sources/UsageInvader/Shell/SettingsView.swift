import AppKit
import SwiftUI

enum SettingsChange { case alias, visibility, order, pollInterval, scanlines }

private enum Palette {
    static let green = Theme.sand
    static let dim = Theme.dim
    static let bg = Theme.bg
    static let field = Theme.surface
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct SettingsView: View {
    let store: UsageStore
    @Bindable var settings: AppSettings
    let onChange: (SettingsChange) -> Void

    @State private var aliasDebounce: Task<Void, Never>?

    private var orderedAccounts: [AccountInfo] {
        let all = store.allAccounts
        let rank = Dictionary(uniqueKeysWithValues: settings.order.enumerated().map { ($1, $0) })
        return all.enumerated().sorted { a, b in
            let ra = rank[a.element.service] ?? (Int.max / 2 + a.offset)
            let rb = rank[b.element.service] ?? (Int.max / 2 + b.offset)
            return ra < rb
        }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("> SETTINGS")
                .font(.pixel(14, bold: true))
                .foregroundStyle(Theme.cream)

            section("ACCOUNTS")
            if store.allAccounts.isEmpty {
                Text("no accounts found — use \"Add account…\" in the menu")
                    .font(Palette.font(11))
                    .foregroundStyle(Palette.dim)
            }
            VStack(spacing: 6) {
                let accounts = orderedAccounts
                ForEach(Array(accounts.enumerated()), id: \.element.service) { idx, acc in
                    accountRow(acc, index: idx, count: accounts.count)
                }
            }

            section("POLLING")
            Picker("", selection: Binding(
                get: { settings.pollInterval },
                set: { settings.pollInterval = $0; onChange(.pollInterval) })) {
                Text("2m").tag(TimeInterval(120))
                Text("5m").tag(TimeInterval(300))
                Text("10m").tag(TimeInterval(600))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            section("DISPLAY")
            Toggle("CRT scanlines", isOn: Binding(
                get: { settings.scanlines },
                set: { settings.scanlines = $0; onChange(.scanlines) }))
                .toggleStyle(.checkbox)
                .font(Palette.font(12))

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 320, alignment: .topLeading)
        .foregroundStyle(Palette.green)
        .tint(Theme.accent)
        .background(Palette.bg)
        .environment(\.colorScheme, .dark)
    }

    private func section(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.pixel(10)).foregroundStyle(Palette.dim)
            Rectangle().fill(Palette.dim.opacity(0.5)).frame(height: 1)
        }
    }

    private func accountRow(_ acc: AccountInfo, index: Int, count: Int) -> some View {
        let visible = !settings.hidden.contains(acc.service)
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { visible },
                set: { on in
                    if on { settings.hidden.remove(acc.service) } else { settings.hidden.insert(acc.service) }
                    onChange(.visibility)
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Visible in overlay")

            VStack(alignment: .leading, spacing: 2) {
                TextField(acc.email ?? acc.displayName ?? acc.service, text: Binding(
                    get: { settings.aliases[acc.service] ?? "" },
                    set: { v in
                        let t = v.trimmingCharacters(in: .whitespaces)
                        settings.aliases[acc.service] = t.isEmpty ? nil : t
                        debounceAlias()
                    }))
                    .textFieldStyle(.plain)
                    .font(Palette.font(12, .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Palette.field)
                    .overlay(Rectangle().stroke(Palette.dim, lineWidth: 1))
                Text([acc.email, acc.plan].compactMap { $0 }.joined(separator: " · ").ifEmpty(acc.service))
                    .font(Palette.font(10))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
            }
            .opacity(visible ? 1 : 0.5)

            Button("▲") { move(index, by: -1) }.disabled(index == 0)
            Button("▼") { move(index, by: 1) }.disabled(index >= count - 1)
        }
        .buttonStyle(.plain)
        .font(Palette.font(12))
    }

    private func move(_ index: Int, by delta: Int) {
        var services = orderedAccounts.map(\.service)
        let j = index + delta
        guard services.indices.contains(index), services.indices.contains(j) else { return }
        services.swapAt(index, j)
        // Keep entries for accounts that are currently not discovered.
        settings.order = services + settings.order.filter { !services.contains($0) }
        onChange(.order)
    }

    private func debounceAlias() {
        aliasDebounce?.cancel()
        aliasDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            onChange(.alias)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(store: UsageStore, onChange: @escaping (SettingsChange) -> Void) {
        let view = SettingsView(store: store, settings: AppSettings.shared, onChange: onChange)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Usage Invader Settings"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x1C/255.0, green: 0x1B/255.0, blue: 0x19/255.0, alpha: 1)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
