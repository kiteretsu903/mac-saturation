// satctl — per-display software saturation for macOS.
//
// Applies a synthesized ICC display profile encoding an exact 3x3 saturation
// matrix to one physical display. The profile is derived from that display's
// factory characterization, so it adds saturation on top of the panel's real
// primaries and tone curve rather than replacing them with sRGB assumptions.
//
// The setting is applied by the system colour pipeline, so it covers the entire
// desktop on that display — apps, video, fullscreen, Mission Control, every
// Space — and leaves other displays alone.
//
// Nothing here is a private API and no permissions are required. The setting
// persists across logout like any display calibration, so it is applied once
// rather than by a daemon.

import Foundation
import CoreGraphics

func usage() -> Never {
    print("""
    satctl — per-display software saturation

      satctl list                    show displays and their index
      satctl set <index> <amount>    apply saturation to one display
      satctl reset <index>           restore the display's normal profile
      satctl reset all               restore every display

      satctl make <percent> [path] [--display <index>]
                                     write a saturation .icc file (100-400)

    <amount>  1.0 = unchanged, 0.0 = grayscale, >1.0 = oversaturated.

    Example:
      satctl set 2 0.70
      satctl set 2 1.00
      satctl make 130
      satctl make 145 ~/Desktop/vivid.icc
    """)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { usage() }

switch verb {
case "list":
    for d in activeDisplays() {
        print("\(d.index)  \(d.name)  [\(d.isBuiltin ? "built-in" : "external")]  "
              + "\(Int(d.size.width))x\(Int(d.size.height))  id=\(d.id)")
    }

case "set":
    guard args.count == 3, let index = Int(args[1]), let amount = Double(args[2]) else {
        usage()
    }
    guard let d = display(at: index) else {
        print("satctl: no display with index \(index); try `satctl list`")
        exit(1)
    }
    guard amount > 0 || amount == 0 else { usage() }

    do {
        if let label = try applySaturation(amount, displayID: d.id, displayName: d.name) {
            print("display \(index) (\(d.name)): saturation \(amount)")
            print("profile name: \(label)")
        } else {
            print("display \(index) (\(d.name)): saturation reset to normal")
        }
    } catch {
        print("satctl: failed to apply profile: \(error)")
        exit(1)
    }

case "make":
    // Writes a standalone .icc without touching any display, so a profile can
    // be generated on one Mac and installed by hand on another.
    guard args.count >= 2, let percent = Double(args[1]) else { usage() }
    guard percent >= 100, percent <= 400 else {
        print("satctl: percent must be between 100 and 400 (got \(formatted(percent)))")
        exit(1)
    }
    // Optionally derive from a live display so the profile carries that panel's
    // real primaries and tone curve instead of sRGB assumptions.
    var base: BaseProfile?
    var label = "Saturation \(formatted(percent))%"
    if let flag = args.firstIndex(of: "--display"), flag + 1 < args.count,
       let n = Int(args[flag + 1]) {
        guard let d = display(at: n) else {
            print("satctl: no display with index \(n); try `satctl list`")
            exit(1)
        }
        base = factoryBaseProfile(displayID: d.id)
        guard let b = base else {
            print("satctl: could not read the factory profile for display \(n)")
            exit(1)
        }
        label = "\(d.name) — Saturation \(formatted(percent))%"
        print("base: \(d.name) factory profile (gamma \(String(format: "%.3f", b.gamma)))")
    }
    let built = base.flatMap { makeSaturationProfileData(saturation: percent / 100.0, base: $0) }
        ?? makeSaturationProfileData(saturation: percent / 100.0)
    guard let raw = built, let data = setProfileDescription(raw, to: label) else {
        print("satctl: could not build a profile for \(formatted(percent))%")
        exit(1)
    }
    let explicitPath = args.count >= 3 && !args[2].hasPrefix("--") ? args[2] : nil
    let out = explicitPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Saturation-\(formatted(percent)).icc")
    do {
        try data.write(to: out)
        print("wrote \(out.path)")
        print("profile name: \(label)")
    } catch {
        print("satctl: could not write \(out.path): \(error.localizedDescription)")
        exit(1)
    }

case "reset":
    guard args.count == 2 else { usage() }
    if args[1] == "all" {
        for d in activeDisplays() {
            restoreProfile(displayID: d.id)
            print("display \(d.index) (\(d.name)): reset")
        }
    } else {
        guard let index = Int(args[1]), let d = display(at: index) else { usage() }
        restoreProfile(displayID: d.id)
        print("display \(index) (\(d.name)): reset")
    }

default:
    usage()
}
