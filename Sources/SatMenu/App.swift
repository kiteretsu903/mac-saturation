// Saturation — a menu bar slider for per-display saturation.
//
// Thin UI over the same ICC mechanism the CLI uses: moving a slider writes a
// display profile derived from that panel's factory characterization. Because
// the profile is what holds the setting, this app does not need to keep
// running — quitting it leaves the adjustment in place.

import SwiftUI
import AppKit
import CoreGraphics
import ServiceManagement

// MARK: - Known panels

/// One-click presets for panels we know need a particular amount of help.
/// The Bigme B251 Pro reports itself over EDID as "ICNM 8001H0".
enum KnownPanel {
    static let bigmePresets: [Double] = [1.3, 1.5, 2.0]

    static func presets(for displayName: String) -> [Double]? {
        let name = displayName.lowercased()
        if name.contains("icnm 8001h0") || name.contains("bigme") {
            return bigmePresets
        }
        return nil
    }
}

// MARK: - Model

struct DisplayEntry: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let index: Int
    let name: String
    let isBuiltin: Bool
    var saturation: Double
}

@MainActor
final class SaturationModel: ObservableObject {
    @Published var displays: [DisplayEntry] = []
    @Published var lastError: String?
    /// Mirrors the real registration state rather than a stored preference, so
    /// the toggle stays honest if macOS drops the login item.
    @Published var launchAtLogin: Bool = false

    private let defaults = UserDefaults.standard

    init() {
        refresh()
        refreshLaunchAtLogin()
        // Displays come and go; keep the list and the sliders in step.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The profile itself holds the setting, so remembered values are only used
    /// to put the sliders back where the user left them.
    private func key(for id: CGDirectDisplayID) -> String { "saturation-\(id)" }

    func refresh() {
        displays = activeDisplays().map { d in
            let stored = defaults.object(forKey: key(for: d.id)) as? Double
            return DisplayEntry(
                id: d.id, index: d.index, name: d.name,
                isBuiltin: d.isBuiltin, saturation: stored ?? 1.0
            )
        }
    }

    func apply(_ amount: Double, to entry: DisplayEntry) {
        guard let i = displays.firstIndex(where: { $0.id == entry.id }) else { return }
        displays[i].saturation = amount
        defaults.set(amount, forKey: key(for: entry.id))
        lastError = nil

        do {
            try applySaturation(amount, displayID: entry.id, displayName: entry.name)
        } catch {
            lastError = "Could not apply to \(entry.name)."
        }
    }

    // MARK: Launch at login

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                // Re-registering an already-enabled service throws, so clear first.
                if SMAppService.mainApp.status == .enabled {
                    try? SMAppService.mainApp.unregister()
                }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "Could not \(enabled ? "enable" : "disable") launch at login."
        }
        refreshLaunchAtLogin()
    }

    func reset(_ entry: DisplayEntry) { apply(1.0, to: entry) }

    func resetAll() {
        for entry in displays { apply(1.0, to: entry) }
    }
}

// MARK: - UI

struct DisplayRow: View {
    @ObservedObject var model: SaturationModel
    // A binding, not a copy: a captured struct would keep reporting its
    // creation-time value during a drag, so the slider would snap back.
    @Binding var entry: DisplayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: entry.isBuiltin ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("\(Int((entry.saturation * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))

            if let presets = KnownPanel.presets(for: entry.name) {
                HStack(spacing: 4) {
                    ForEach(presets, id: \.self) { value in
                        Button("\(Int(value * 100))%") {
                            entry.saturation = value
                            model.apply(value, to: entry)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(abs(entry.saturation - value) < 0.001 ? .accentColor : nil)
                    }
                }
                .font(.system(size: 11))
            }

            HStack(spacing: 8) {
                Slider(
                    value: $entry.saturation,
                    in: 0.0...3.0,
                    // Applying on every drag frame would reinstall the display
                    // profile continuously, so commit only when the drag ends.
                    onEditingChanged: { editing in
                        if !editing { model.apply(entry.saturation, to: entry) }
                    }
                )
                Button {
                    model.reset(entry)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset \(entry.name) to normal")
                .disabled(abs(entry.saturation - 1.0) < 0.001)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: SaturationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Display Saturation")
                .font(.system(size: 13, weight: .semibold))

            if model.displays.isEmpty {
                Text("No displays found.").foregroundStyle(.secondary)
            } else {
                ForEach($model.displays) { $entry in
                    DisplayRow(model: model, entry: $entry)
                }
            }

            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))

            HStack {
                Button("Reset All") { model.resetAll() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.system(size: 12))

            Text("Settings are stored in the display profile and stay applied after quitting.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        // Headless check used to verify login-item registration works for this
        // bundle (ad-hoc signatures are the doubtful case).
        let args = CommandLine.arguments
        if args.contains("--login-status") {
            print("status: \(SMAppService.mainApp.status.rawValue) "
                  + "(1 = enabled, 0 = notRegistered, 3 = notFound)")
            exit(0)
        }
        if args.contains("--login-enable") {
            do { try SMAppService.mainApp.register(); print("registered ok") }
            catch { print("register FAILED: \(error)") }
            print("status now: \(SMAppService.mainApp.status.rawValue)")
            exit(0)
        }
        if args.contains("--login-disable") {
            do { try SMAppService.mainApp.unregister(); print("unregistered ok") }
            catch { print("unregister FAILED: \(error)") }
            print("status now: \(SMAppService.mainApp.status.rawValue)")
            exit(0)
        }
        // Menu bar only — no Dock icon, never takes focus from other apps.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct SaturationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = SaturationModel()

    var body: some Scene {
        MenuBarExtra("Saturation", systemImage: "circle.lefthalf.filled") {
            ContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
