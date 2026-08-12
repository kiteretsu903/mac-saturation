# satctl

Per-display software saturation control for macOS — the one BetterDisplay
feature, as a small Swift CLI plus a menu bar app, using only public APIs and
no permissions.

Written for a **Bigme B251 Pro** (which identifies itself over EDID as
`ICNM 8001H0`) to compensate for its limited colour gamut, but nothing here is
specific to that panel — it works on any display macOS can assign a profile to.

### Menu bar app

```
./build.sh
open Saturation.app
```

A slider per display, listed automatically, with a reset button each and
"Reset All". It sets the same ICC profiles the CLI does, so **the app does not
need to keep running** — quitting leaves the adjustment in place. The slider
commits when you release it rather than on every drag frame, since each change
reinstalls a display profile.

Because it is ad-hoc signed rather than notarized, the first launch may need
right-click > Open.

### CLI

```
satctl list
satctl set 2 0.70      # 1.0 = unchanged, 0.0 = grayscale, >1.0 = oversaturated
satctl reset 2
satctl reset all

satctl make 130                    # write Saturation-130.icc (100-400)
satctl make 150 out.icc --display 1   # derive from that display's panel
satctl make 145 ~/Desktop/vivid.icc
```

`make` generates a standalone `.icc` without touching any display, so you can
build a profile on one Mac and install it by hand on another.

Ready-made profiles are in [`profiles/`](profiles/): a set built from the Bigme
B251 Pro's own factory characterization (130/140/150/200%) and generic
sRGB-based ones for other displays.
To use them without building anything: copy the `.icc` into
`~/Library/ColorSync/Profiles/`, then pick it in System Settings > Displays >
Colour Profile.

| profile | sky-blue spread |
|---|---|
| (none / 100%) | 0.398 |
| Bigme 130% | 0.550 |
| Bigme 140% | 0.594 |
| Bigme 150% | 0.639 |
| Bigme 200% | 0.903 |

`set` and `make --display` derive from the target display's **factory profile**,
keeping its measured primaries and tone curve and adding saturation on top
(`M_new = M_display · S⁻¹`). This matters: the Bigme's real tone curve is gamma
**1.961**, not the 2.2 that earlier versions assumed, and that mismatch shifted
every midtone.

Build both:

```
./build.sh
```

## How it works

macOS colour-manages every pixel from its source colour space into the target
**display's ICC profile**, per display, in the scanout stage of the pipeline.
That conversion is a full 3×3 matrix, which is exactly the cross-channel mixing
a saturation transform requires — and exactly what a 1D gamma LUT
(`CGSetDisplayTransferByTable`) cannot express.

So instead of filtering pixels, `satctl` synthesizes a display profile that
makes the system's own colour conversion perform the saturation:

- The compositor computes `displayRGB = M⁻¹ · XYZ` using the display's profile
  matrix `M`.
- We want an extra saturation `S` applied on top of the panel's real behaviour.
- Therefore the profile matrix must be `M_new = M_display · S⁻¹`, where
  `M_display` comes from the display's **factory** profile.

Deriving from the factory profile rather than assuming sRGB matters. The Bigme's
measured tone curve is gamma **1.961**; earlier versions of this tool hardcoded
2.2, which shifted every midtone as an unintended side effect of adding
saturation. `make` without `--display` still falls back to sRGB assumptions,
since it has no panel to read.

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

It runs a fullscreen overlay window, literally named
`BetterDisplay Compositor Filter Overlay for Display 3` and sized exactly to the
display. What that overlay does is **not** settled here. Its binary imports
ScreenCaptureKit, CoreImage and Metal, and an earlier version of this README
concluded from that it captures the screen and re-renders it — and therefore
needs Screen Recording permission.

That conclusion was not supported. BetterDisplay has other features (virtual
display streaming) that would import ScreenCaptureKit anyway, and users report
that its saturation works without granting Screen Recording.

A permission-free mechanism does exist and is verified here: a `CALayer`
**compositing** filter on an overlay window, using the private
`kCAFilterSaturationBlendMode`. Measured on macOS 27 with a fullscreen overlay
over one display:

| overlay | result RGB | mean saturation |
|---|---|---|
| baseline | (198.4, 206.5, 199.9) | 0.0825 |
| `multiplyBlendMode`, red | (179.6, 46.4, 46.4) | 0.7548 |
| `saturationBlendMode`, red | (194.1, 217.0, 198.5) | **0.1625** |
| `saturationBlendMode`, red @ 50% alpha | (195.0, 212.2, 198.5) | 0.1402 |
| red at 50% alpha, no filter (control) | (212.4, 122.0, 119.0) | 0.4542 |

The multiply row is the proof that WindowServer really is blending with the
desktop behind the window rather than compositing an opaque layer over it —
compare the control. `saturationBlendMode` doubles measured saturation while
holding luminance, and layer alpha scales the strength.

This is very likely what BetterDisplay's overlay does, but that is inference
from the mechanism being available and sufficient — not a confirmed reading of
its code.

### satctl vs an overlay approach

| | satctl (ICC profile) | overlay + compositing filter |
|---|---|---|
| Permissions | none | none |
| Running process | none | one, for as long as the effect is wanted |
| Survives logout | yes | no, must be relaunched |
| Private API | none | `CAFilter` blend modes |
| Screenshots | unaffected (scanout stage) | baked into captures |

**The colour maths is not the difference between the two.** Rendering the same
colours through CoreImage's `CIColorControls` saturation and through this tool's
generated profile gives near-identical results — differences around 0.01, and
luminance changes under 0.012, tracking closely even at 200% and 300%.

The two real differences in appearance are:

- **Tone curve.** Getting the panel's actual gamma right (1.961 here, not 2.2)
  mattered more than the saturation maths.
- **Slider scale.** BetterDisplay's "130%" is not CoreImage saturation 1.3, so
  matching it by eye needs a larger number here. That is why `make` allows up
  to 400%.

## What does NOT work on modern macOS

Two commonly-cited "compositor filter" approaches were tested on macOS 27 and
both are dead ends:

**`CGSAddWindowFilter` / `CGSNewCIFilterByName`** (private SkyLight, re-exported
through CoreGraphics). The symbols are still live, but WindowServer now accepts
almost nothing: of **266** candidate filter names tried (every
`CIFilter.filterNames` plus every exported `kCAFilter*` constant), exactly one
was accepted — `CIColorInvert`. `colorSaturate`, `colorMatrix`, `CIColorControls`
and the rest all return error `1006`.

**`CALayer.backgroundFilters`** with a private `CAFilter`. (Note that
`compositingFilter` *does* work — see above. It is specifically the *backdrop*
filter path that is dead.) The `CAFilter` class
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

- Wide-gamut (P3) and HDR content is mapped through the same profile, so extreme
  settings can clip in-gamut colours.
- `make` without `--display` assumes sRGB primaries and gamma 2.2. Prefer `set`
  or `make --display` so the panel's real characterization is used.
- Replaces the display's calibration profile, so it is not compatible with a
  custom calibration on the same display.
- `s = 0.0` is clamped to `0.001`, since the saturation matrix is singular at
  exactly zero.
- Oversaturation has no effect on colours already at the edge of sRGB: pure red,
  green, blue and cyan are already maximally saturated, so boosting pushes them
  out of gamut and they clip back to the same corner. The visible effect is on
  photographic and mid-range colours. Verified on the Bigme: at 130% a sky blue
  moves from spread 0.398 to 0.550, while pure primaries are unchanged.
