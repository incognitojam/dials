# nitMac follow-ups

Polish noticed while using the installed app. None of these are bugs.

## Bounce the glyph at the ends of the range

The system brightness slider bounces the sun when you reach minimum or maximum: the rays jump out and back in. nitMac just stops. `symbolEffect(.bounce)` is the matching API, triggered when a key press lands on 0 or 100 rather than on every press.

## The slider track is blue, not white

SwiftUI's `Slider` fills with the accent colour, which resolves to blue under a Multicolour appearance. Control Center's Display card measures a pure white fill on a 16% white track, which is also what the indicator draws, so the two surfaces disagree.

Open question: match Control Center exactly, or treat the accent colour as the user's stated preference and leave it. Worth checking whether the system slider exposes a hint for this rather than guessing.

## The slider handle may lag the cursor

Dragging feels less responsive than the system's menu bar slider — the handle follows the cursor at a lower rate. This is about the handle's own frame rate, not about how quickly the brightness applies. Unproven; needs measuring before chasing.

Writes are not the obvious suspect: `DisplayServicesSetBrightness` measures 0.02 ms. More likely the whole panel re-rendering on every binding change, since the slider's value is derived from a `@Published` array the rest of the panel also reads.

## Possibly drop the percentage

The panel shows the display name, a percentage and a slider. The percentage may be redundant against the slider position. Undecided — the system's own panel does not show one.

## The indicator will not match the system brightness panel

These measurements describe Tahoe. Golden Gate changes Liquid Glass rendering and replaces the Clear/Tinted appearance choice with a slider; remeasure before using these values to tune the HUD on macOS 27. The HUD now leaves its glass edge to the system on macOS 27. See [compatibility notes](development.md#macos-27-golden-gate).

The system panel is more vivid than the indicator, which reads slightly milky beside it. Measured against a flat backdrop of `(60, 120, 40)`, its interior comes out `(31, 118, 5)`: brightness held, red and blue crushed. That is a saturation boost, which is how the pre-Tahoe vibrancy materials behave and is not something Liquid Glass does. `NSVisualEffectView` with `.hudWindow` has the same character but arrives darker, at `(39, 94, 13)`.

Neither glass variant reproduces it. `.regular` saturates but goes very dark, `(12, 59, 0)`; `.clear` barely alters the backdrop at all, `(58, 113, 39)`.

Two things not to repeat here:

- Appearance › Liquid Glass offers Clear and Tinted, where Clear is the standard material and Tinted is the more opaque one. That setting has nothing to do with `Glass.clear`, which is the variant for small controls over photos and maps and is meant to be paired with a dimming layer. Matching the two by name gives the milky panel.
- The system panel is drawn by `OSDUIHelper`, a system process, so there is no public API for the material it uses. Parity is not reachable; deciding the indicator should simply look like itself is a reasonable answer.
