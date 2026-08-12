// Saturation — a menu bar slider for per-display saturation.
//
// Thin UI over the same ICC mechanism the CLI uses: moving a slider writes a
// display profile derived from that panel's factory characterization. Because
// the profile is what holds the setting, this app does not need to keep
// running — quitting it leaves the adjustment in place.

import SwiftUI
import AppKit
import CoreGraphics

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

    private let defaults = UserDefaults.standard

    init() {
        refresh()
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

        // Exactly 1.0 means "no adjustment" — drop the override rather than
        // leaving an identity profile over the display's real calibration.
        guard abs(amount - 1.0) > 0.001 else {
            restoreProfile(displayID: entry.id)
            return
        }

        let base = factoryBaseProfile(displayID: entry.id)
        let built = base.flatMap { makeSaturationProfileData(saturation: amount, base: $0) }
            ?? makeSaturationProfileData(saturation: amount)
        guard let raw = built else {
            lastError = "Could not build a profile for \(entry.name)."
            return
        }
        let label = "\(entry.name) — Saturation \(Int((amount * 100).rounded()))%"
        let data = setProfileDescription(raw, to: label) ?? raw
        do {
            _ = try installProfile(data, displayID: entry.id, tag: "\(entry.id)")
        } catch {
            lastError = "Could not apply to \(entry.name)."
        }
    }

    func reset(_ entry: DisplayEntry) { apply(1.0, to: entry) }

    func resetAll() {
        for entry in displays { apply(1.0, to: entry) }
    }
}

// MARK: - UI

struct DisplayRow: View {
    @ObservedObject var model: SaturationModel
    let entry: DisplayEntry

    private var binding: Binding<Double> {
        Binding(
            get: { entry.saturation },
            // Applying on every drag frame would reinstall the profile
            // continuously, so the slider only commits when the drag ends.
            set: { value in
                if let i = model.displays.firstIndex(where: { $0.id == entry.id }) {
                    model.displays[i].saturation = value
                }
            }
        )
    }

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

            HStack(spacing: 8) {
                Slider(
                    value: binding,
                    in: 0.0...3.0,
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
                ForEach(model.displays) { entry in
                    DisplayRow(model: model, entry: entry)
                }
            }

            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            Divider()

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
