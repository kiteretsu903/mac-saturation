# satctl

Per-display software saturation control for macOS — the one BetterDisplay
feature, as ~300 lines of Swift, using only public APIs and no permissions.

Written for a **Bigme B251 Pro** (which identifies itself over EDID as
`ICNM 8001H0`) to compensate for its limited colour gamut, but nothing here is
specific to that panel — it works on any display macOS can assign a profile to.

```
satctl list
satctl set 2 0.70      # 1.0 = unchanged, 0.0 = grayscale, >1.0 = oversaturated
satctl reset 2
satctl reset all

satctl make 130                    # write Saturation-130.icc (100-180)
satctl make 145 ~/Desktop/vivid.icc
```

`make` generates a standalone `.icc` without touching any display, so you can
build a profile on one Mac and install it by hand on another.

Ready-made profiles are in [`profiles/`](profiles/) — 130%, 140% and 150%.
To use them without building anything: copy the `.icc` into
`~/Library/ColorSync/Profiles/`, then pick it in System Settings > Displays >
Colour Profile.

| profile | sky-blue spread |
|---|---|
| (none / 100%) | 0.398 |
| Saturation 130% | 0.519 |
| Saturation 140% | 0.561 |
| Saturation 150% | 0.605 |

Build:

```
swiftc -O Sources/satctl/*.swift -o satctl
```

## How it works

macOS colour-manages every pixel from its source colour space into the target
**display's ICC profile**, per display, in the scanout stage of the pipeline.
That conversion is a full 3×3 matrix, which is exactly the cross-channel mixing
a saturation transform requires — and exactly what a 1D gamma LUT
(`CGSetDisplayTransferByTable`) cannot express.

So instead of filtering pixels, `satctl` synthesizes a display profile that
makes the system's own colour conversion perform the saturation:

- The compositor computes `displayRGB = M⁻¹ · XYZ`, and content arrives as
  `XYZ = M_sRGB · srcRGB`.
- We want `displayRGB = S · srcRGB` for saturation matrix `S`.
- Therefore the profile matrix must be `M = M_sRGB · S⁻¹`.

`S` is the standard luminance-preserving saturation matrix
`S = s·I + (1−s)·1·wᵀ` with Rec.709 weights `w`. Its inverse has a closed form
via Sherman-Morrison (using `wᵀ·1 = 1`):

```
S⁻¹ = (1/s)·I − ((1−s)/s)·1·wᵀ
```

The profile is written to `~/Library/ColorSync/Profiles/` and assigned to one
display with `ColorSyncDeviceSetCustomProfiles`.

### Verified properties

Colour math checked by converting reference colours through the generated
profile with ColorSync. At `s = 0.0` every hue collapses to its correct
luminance gray (red → 0.506, green → 0.859, blue → 0.280, matching Rec.709
weights to within ICC quantization), with channel spread ≤ 0.002. Neutrals stay
exactly neutral at every setting.

Visually confirmed on macOS 27.0 (arm64): external display grayscale, built-in
display untouched. Mechanism confirmed identical to BetterDisplay's (above).

- Covers the whole desktop: apps, video, fullscreen, Mission Control, all Spaces.
- Scoped to one physical display; others are unaffected.
- No private APIs, no Accessibility or Screen Recording permission, no SIP changes.
- Persists across logout like any display calibration, so there is no daemon.

## How this differs from BetterDisplay

**BetterDisplay does not use this mechanism.** An earlier version of this README
claimed it did, inferred from the fact that its binary imports
`ColorSyncDeviceSetCustomProfiles` and `CGSetDisplayTransferByTable`. That
inference was wrong: it imports those for its *gamma/gain* controls, not for
saturation.

Measured directly, with BetterDisplay's saturation set to 130% and active on the
display: the assigned ICC profile was still the stock one and the gamma table
was still identity — byte-for-byte identical to the untouched baseline. It
changes neither.

What it actually does, from its linked frameworks and its on-screen windows:

```
_OBJC_CLASS_$_SCStream, _SCContentFilter      ScreenCaptureKit
_OBJC_CLASS_$_CIContext, kCIContextWorkingColorSpace   CoreImage
_MTLCreateSystemDefaultDevice, _CVPixelBufferGetIOSurface   Metal
```

plus a window literally named
`BetterDisplay Compositor Filter Overlay for Display 3`, sized exactly to the
display. It **captures the display, applies a CoreImage filter on the GPU, and
draws the filtered frames into a fullscreen overlay**. Despite the name, it does
not filter the compositor — it re-renders the screen on top of itself.

### Practical consequences

| | satctl (ICC profile) | BetterDisplay (capture + filter) |
|---|---|---|
| Screen Recording permission | not needed | **required** |
| Running process | none | continuous capture + GPU work |
| Power cost | zero | ongoing |
| Luminance | preserved by construction | not preserved — looks brighter |
| Out-of-gamut colours | clip at the gamut edge | filtered before display mapping |

The last two rows are why BetterDisplay looks more vivid at the same nominal
percentage. `satctl` rotates colour around the Rec.709 luma axis, so brightness
is mathematically unchanged; BetterDisplay's filter runs earlier in the pipeline
and does not hold luminance fixed. They are not comparable on a common scale —
BetterDisplay at 130% is a stronger effect than `satctl` at 150%.

## What does NOT work on modern macOS

Two commonly-cited "compositor filter" approaches were tested on macOS 27 and
both are dead ends:

**`CGSAddWindowFilter` / `CGSNewCIFilterByName`** (private SkyLight, re-exported
through CoreGraphics). The symbols are still live, but WindowServer now accepts
almost nothing: of **266** candidate filter names tried (every
`CIFilter.filterNames` plus every exported `kCAFilter*` constant), exactly one
was accepted — `CIColorInvert`. `colorSaturate`, `colorMatrix`, `CIColorControls`
and the rest all return error `1006`.

**`CALayer.backgroundFilters`** with a private `CAFilter`. The `CAFilter` class
and its `colorSaturate` type still exist and instantiate fine, and CoreAnimation
accepts and stores the filter — but it is a **no-op**. Tested with
`colorSaturate`, `colorInvert`, `gaussianBlur`, `colorBrightness` and
`colorMonochrome` on a click-through overlay window pinned above the shielding
window level: measured mean saturation and mean RGB were unchanged in every
case. A control experiment (solid 50% red overlay, same window configuration)
moved measured saturation from 0.112 → 0.633, confirming the overlay and the
measurement harness were both working.

## A note on verifying this yourself

`screencapture` **cannot** see scanout-stage colour transforms. Setting a gamma
LUT that drives green and blue to 20% returns success and is plainly visible on
the physical display, yet screenshots come back byte-for-byte unchanged
(measured RGB `199.0,210.4,201.5` → `198.8,210.1,201.2`).

This cuts both ways: screenshots are useless for confirming that `satctl` works,
but they also prove the compositor-filter approaches genuinely failed rather
than merely being invisible to capture.

## Limitations

- Assumes sRGB-like source content. Wide-gamut (P3) and HDR content is mapped
  through the same profile, so extreme settings can clip in-gamut colours.
- Replaces the display's calibration profile, so it is not compatible with a
  custom calibration on the same display.
- `s = 0.0` is clamped to `0.001`, since the saturation matrix is singular at
  exactly zero.
- Oversaturation has no effect on colours already at the edge of sRGB: pure red,
  green, blue and cyan are already maximally saturated, so boosting pushes them
  out of gamut and they clip back to the same corner. The visible effect is on
  photographic and mid-range colours. Verified: at 130% a sky blue moves from
  spread 0.398 to 0.519, while pure primaries are unchanged.
