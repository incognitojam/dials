# @dials/neqmac

## 0.3.0

### Minor Changes

- 05ebc0a: Apply a corrective equalizer profile to the current USB output by editing equalizer.json. Activity shows when the profile is applied or processing stops.

### Patch Changes

- c44b9b7: USB outputs with their own input streams are not supported by the equalizer.
- d272b92: The equalizer now starts on the selected USB output and explains when it cannot read the device.
- 200ea33: The equalizer automatically resumes after the USB output changes sample rate during playback.

## 0.2.0

### Minor Changes

- cce053b: Redesign the Routing priority lists. Drag a device to reorder it instead of clicking up and down arrows, and drag it below the new Never use divider to exclude it. Each device shows an icon for how it connects, Use Now appears on hover or with a double-click, and Edit selects several devices at once to exclude, allow or remove ones you no longer use. New devices join the list next to others of the same connection type rather than at the bottom, and a USB device without a serial number, such as the Schiit Fulla, keeps one entry instead of a new one for each port it is plugged into.

## 0.1.0

### Minor Changes

- a1386d8: Initial release.
