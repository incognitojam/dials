# USB output equalizer

On macOS 14.2 or later, neqMac can apply a copied OPRA profile to the current USB output.
Create `~/Library/Application Support/neqMac/equalizer.json` and replace the example UID
with the output UID from your routing rule. Keep this file private. The first matching
assignment in file order wins. Matching uses the routing rules for exact UIDs, serial-less
USB devices moved between ports, and named AirPlay devices. Only USB outputs are eligible.

```json
{
  "enabled": true,
  "assignments": [
    {
      "uid": "AppleUSBAudioEngine:Example:Test DAC:SERIAL0A:1",
      "name": "Test DAC",
      "transport": "USB",
      "choice": "profile",
      "allowDuplexInput": false,
      "enabled": true,
      "profile": {
        "type": "parametric_eq",
        "author": "Example",
        "details": "Synthetic listening check",
        "parameters": {
          "gain_db": -12,
          "bands": [
            { "type": "low_pass", "frequency": 1000, "slope": 12 }
          ]
        }
      }
    }
  ]
}
```

USB outputs with input streams require `"allowDuplexInput": true` on their own assignment.
It defaults to false. With the default, Activity shows the device stream and channel counts
before suspending. Opting in permits a verification attempt. The tap stream must retain
its identity when neqMac attaches the output, its format and channels must match, and
the aggregate must accept the tap-only IO-proc input mask. Activity records the selected
stream, buffer range and build timings. An unverifiable layout suspends processing.

Both enabled switches default to false. The assignment list defaults to empty. Each
assignment needs a nonempty UID and a choice. Name and transport default to empty strings.
Use `"choice": "none"` and omit `profile` to record an explicit “No equalizer”. Remove the
assignment to leave the output unassigned. For a profile, copy the complete OPRA
`eq_info`, including its author and any measurement details, product ID and source link.
Unknown fields are ignored. A malformed assignment disables the whole file and appears in
Activity. neqMac only reads the file. Saving, replacing or deleting it takes effect live.

An enabled matching assignment authorizes the first tap attempt, including when launched
with that file already present. Allow the microphone and system audio capture requests.
The menu and routing stay responsive while the system waits. If playback goes silent,
turn either switch off or move the file aside. Quit neqMac if direct playback does not
resume. Check Privacy & Security before enabling the assignment again. Paused players
and denied taps can both deliver silence, so Activity cannot establish permission from
sample values.

The session follows the settled default output, suspends below 32 kHz and compiles the
profile at the tap's negotiated rate. It reads the current buffer size and leaves it to the device. Profile
updates keep the running tap. Switching off releases it. A callback stall during active
playback releases the tap before IO shutdown, which can take longer. After an observed
failure, edit the file or change outputs to retry. After two failures on the same output,
save an edit to retry it. Inspect **Activity** for the reason. The watchdog checks other
processes and callback progress every 50 ms with a 350 ms gap tolerance. Device removal requires evidence from the physical device. A transient empty aggregate
output list during a clock change can recover on a subsequent format notification. A whole-process freeze
also freezes the watchdog; force-quit neqMac to release the mute in that case.


Playback reserves headroom whenever the compiled preamp and filters together exceed
0 dB. Activity gives the reduction in dB. The copied profile retains the entered gain.
The same reduction applies to compare gain, and a final sample clamp bounds the
rendered output to full scale. These limits do not establish a safe listening volume.
