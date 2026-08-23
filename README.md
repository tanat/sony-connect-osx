# SonyConnect macOS — XM6-focused fork

SonyConnect is a macOS menu-bar controller for Sony headphones over Bluetooth.
This repository is an XM6-focused continuation of the original project:

- Original project: [tanat/sony-connect-osx](https://github.com/tanat/sony-connect-osx)
- V2 fork: [Stetco-lab/sony-connect-osx](https://github.com/Stetco-lab/sony-connect-osx)
- This fork: expanded WH-1000XM6 support, protocol discovery, Multipoint controls, and menu-bar UI improvements.

The XM6 work was developed and hardware-tested against a Sony WH-1000XM6. The
original XM4 functionality remains part of the project, but protocol support is
device- and firmware-specific.

## XM6 additions

### Dynamic capability discovery

- Discovers firmware-defined General Setting slots instead of assuming a fixed slot.
- Identifies Multipoint, touch-panel, pairing, wearing-detection, listening-mode,
  and other capabilities from device responses.
- Keeps unsupported or unverified controls from sending guessed protocol writes.

### Multipoint manager

- Toggle Multipoint on and off.
- Read the live connected-device list and connection slots.
- Show the current playback device.
- Connect and disconnect known Multipoint devices.
- Switch playback between connected devices.
- Swap in a known device while protecting this Mac through the two-phase operation.
- Show “Swapping…” while a replacement is in progress.
- Enter and stop pairing mode when the device permits it.
- Keep the flattened manager directly in the main menu instead of hiding it behind
  a separate Device Manager submenu.

### XM6 controls

- Noise Cancelling, Ambient Sound, and Off.
- Auto Ambient Sound and its discovered sensitivity control when supported.
- Listening Mode: Standard, Background Music, and Cinema.
- Background Music room profiles: My Room, Living Room, and Cafe.
- Speak-to-Chat on/off with discovered sensitivity and timeout settings.
- Touch Sensor.
- Wearing Detection, including pause-media-on-removal behavior.
- Auto Power Off and headphone power-off controls.

### Menu-bar and reliability work

- XM6 headphone icon with optional battery percentage.
- Live battery level and charging-state notifications.
- Mac output-volume slider with live refresh while the menu is open, including
  changes made with the keyboard volume keys.
- Reconnect and recovery behavior for a hidden or stale menu-bar item.
- Menu views that remain open while supported settings are changed.
- Auto Layout ordering fixes for macOS versions that reject cross-hierarchy
  constraints.
- Capability-gated actions and safety checks around Multipoint operations.

## Supported headphones

The primary target of this fork is the **Sony WH-1000XM6**. The inherited
WH-1000XM4 code path remains available, and other Sony models may work where
their capability tables and protocol values match. Do not assume that an XM6
command is safe to use on another model.

## Requirements

- macOS 12 Monterey or newer
- Xcode Command Line Tools (`xcode-select --install`)
- Headphones already paired in System Settings → Bluetooth

## Build and run

```sh
make run
```

This builds a release binary, creates `SonyConnect.app`, ad-hoc signs it, stops
an older instance, and opens the new build. macOS may request Bluetooth access
on first launch.

For a manual release build:

```sh
swift build -c release
```

The app is currently ad-hoc signed and not notarized. Users may need to approve
the app in macOS Security & Privacy settings.

## Protocol notes

Sony headphones expose a proprietary RFCOMM service on top of classic Bluetooth.
The framing, escaping, checksums, capability negotiation, and notification
handling are inherited from the upstream project and related reverse-engineering
work. XM6-specific behavior is discovered where possible from the connected
device rather than inferred from the model name alone.

The most important XM6 Multipoint read path is the connected-device query
(`0x36 0x02`), followed by the discovered Multipoint General Setting read. The
application logs capability discovery and Multipoint state to:

```text
~/Library/Logs/SonyConnect.log
```

Protocol writes remain intentionally conservative: unknown opcodes and payloads
are not guessed.

## Project layout

```text
Sources/SonyConnect/
  MenuBarController.swift       — menu-bar item, menu, routing, and UI state
  HeadphonesController.swift    — Bluetooth protocol state machine
  MultipointMenuView.swift      — flattened XM6 Multipoint manager
  ListeningModeMenuView.swift   — XM6 listening-mode UI
  BluetoothClient.swift         — RFCOMM wrapper and reachability
  SonyPacket.swift              — Sony frame encoding and decoding
  VolumeController.swift        — CoreAudio output-volume control
  EqualizerView.swift           — graphic EQ controls
  MediaController.swift         — media pause/resume integration
  FileLogger.swift              — diagnostic log output
Resources/Info.plist            — app metadata and Bluetooth usage description
Makefile                        — build, package, sign, and run helpers
Package.swift                   — Swift Package Manager manifest
```

## Limitations

- The Sony protocol is reverse-engineered and may change with firmware updates.
- Hardware validation has been performed primarily with one WH-1000XM6 setup.
- The app is ad-hoc signed only; it is not a notarized commercial distribution.
- Feature availability depends on what the connected headphones advertise.
- Codec readout, firmware-version readout, DSEE Extreme, Adaptive Sound Control,
  Quick Access assignment, and a Dock application are not part of this release.

## Credits and relationship to upstream

Please treat this as a collaborative fork, not a replacement for the original
authors. The project builds on:

- [tanat/sony-connect-osx](https://github.com/tanat/sony-connect-osx)
- [Stetco-lab/sony-connect-osx](https://github.com/Stetco-lab/sony-connect-osx)
- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge)
- [SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient)

The XM6 additions are intended to be reviewed upstream. Please report the
headphone model, firmware, relevant log excerpt, and the exact action that
failed when filing an issue.

## License

This fork currently does not add a new license file. Before distributing
compiled copies or relicensing the code, please confirm the licensing terms
with the upstream maintainers.
