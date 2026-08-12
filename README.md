# satctl

Per-display software saturation control for macOS — the one BetterDisplay
feature, as ~250 lines of Swift, using only public APIs and no permissions.

```
satctl list
satctl set 2 0.70      # 1.0 = unchanged, 0.0 = grayscale, >1.0 = oversaturated
satctl reset 2
satctl reset all
```

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
display untouched.

- Covers the whole desktop: apps, video, fullscreen, Mission Control, all Spaces.
- Scoped to one physical display; others are unaffected.
- No private APIs, no Accessibility or Screen Recording permission, no SIP changes.
- Persists across logout like any display calibration, so there is no daemon.

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
