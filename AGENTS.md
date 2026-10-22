# Agent instructions

This repository is public. Everything committed here, including history, test fixtures, docs, commit messages and pull request text, can be read by anyone.

## Hardware identifiers and personal data

Never commit identifiers taken from real hardware or a real machine. That includes:

- serial numbers, and device UIDs or model strings that embed them, such as CoreAudio UIDs like `AppleUSBAudioEngine:<vendor>:<product>:<serial>:<n>`
- display EDIDs and serial numbers, `CGDirectDisplayID`s copied from a real setup
- MAC addresses, Bluetooth addresses, AirPlay device IDs
- personal names in device names (`Jane's AirPods`), Wi-Fi network names, hostnames and IP addresses
- home-directory paths that include a username, and screenshots, logs or command output that show any of the above

Probing real hardware is often the only way to learn a format. Keep that output in an untracked file, and when a test or doc needs an example, rewrite it with obviously synthetic values that keep the same shape, such as `SERIAL0A`, `00:11:22:33:44:55` or `Test Headphones`. Before committing, read the diff for values copied from a real device.

If one has already been committed on a branch that has not been pushed, rewrite that branch's commits so the value is gone from history rather than adding a fixup on top. If it has been pushed, stop and tell the user.
