# Follow-ups

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
