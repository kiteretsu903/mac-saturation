// satctl — per-display software saturation for macOS.
//
// Applies a synthesized ICC display profile encoding an exact 3x3 saturation
// matrix to one physical display. The setting is applied by the system colour
// pipeline, so it covers the entire desktop on that display — apps, video,
// fullscreen, Mission Control, every Space — and leaves other displays alone.
//
// Nothing here is a private API and no permissions are required. The setting
// persists across logout like any display calibration, so it is applied once
// rather than by a daemon.

import Foundation
import CoreGraphics
import AppKit

struct Display {
    let id: CGDirectDisplayID
    let index: Int
    let isBuiltin: Bool
    let name: String
    let size: CGSize
}

func activeDisplays() -> [Display] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)

    return ids.enumerated().map { index, id in
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID) == id
        }
        return Display(
            id: id,
            index: index + 1,
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            name: screen?.localizedName ?? "Display \(id)",
            size: screen?.frame.size ?? CGDisplayBounds(id).size
        )
    }
}

func display(at index: Int) -> Display? {
    activeDisplays().first { $0.index == index }
}

/// Renders a percentage without a trailing ".0" so profile names read as
/// "Saturation 130%" rather than "Saturation 130.0%".
func formatted(_ value: Double) -> String {
    value == value.rounded()
        ? String(Int(value.rounded()))
        : String(format: "%g", value)
}

func usage() -> Never {
    print("""
    satctl — per-display software saturation

      satctl list                    show displays and their index
      satctl set <index> <amount>    apply saturation to one display
      satctl reset <index>           restore the display's normal profile
      satctl reset all               restore every display

      satctl make <percent> [path]   write a saturation .icc file (100-180)

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

    // 1.0 means "no adjustment" — drop the override entirely rather than
    // installing an identity profile over the display's real calibration.
    if amount == 1.0 {
        restoreProfile(displayID: d.id)
        print("display \(index) (\(d.name)): saturation reset to normal")
        break
    }
    guard let raw = makeSaturationProfileData(saturation: amount) else {
        print("satctl: could not build a profile for saturation \(amount)")
        exit(1)
    }
    // Give it a name that is identifiable in System Settings > Displays.
    let label = "\(d.name) — Saturation \(Int((amount * 100).rounded()))%"
    let data = setProfileDescription(raw, to: label) ?? raw
    do {
        _ = try installProfile(data, displayID: d.id, tag: "\(d.id)")
        print("display \(index) (\(d.name)): saturation \(amount)")
        print("profile name: \(label)")
    } catch {
        print("satctl: failed to apply profile: \(error)")
        exit(1)
    }

case "make":
    // Writes a standalone .icc without touching any display, so a profile can
    // be generated on one Mac and installed by hand on another.
    guard args.count == 2 || args.count == 3, let percent = Double(args[1]) else {
        usage()
    }
    guard percent >= 100, percent <= 180 else {
        print("satctl: percent must be between 100 and 180 (got \(formatted(percent)))")
        exit(1)
    }
    let label = "Saturation \(formatted(percent))%"
    guard let raw = makeSaturationProfileData(saturation: percent / 100.0),
          let data = setProfileDescription(raw, to: label) else {
        print("satctl: could not build a profile for \(formatted(percent))%")
        exit(1)
    }
    let out = args.count == 3
        ? URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
