# Changelog

## XM6-focused fork — unreleased

This release documents the XM6 work developed on top of the original SonyConnect
project and the Stetco-lab v2 fork.

### Added

- Dynamic capability discovery for firmware-defined XM6 settings.
- Flattened XM6 Multipoint manager in the main menu.
- Multipoint on/off state and connected-device discovery.
- Known-device connect/disconnect and playback switching.
- Two-phase Swap In behavior that protects this Mac during replacement.
- Swap progress feedback and pairing-mode controls.
- Standard, Background Music, and Cinema listening modes.
- Background Music room profiles.
- Wearing Detection with pause-media-on-removal behavior.
- Auto Ambient Sound and discovered sensitivity support where advertised.
- Speak-to-Chat configuration controls.
- Live battery percentage and charging notifications.
- Live menu-open volume refresh for keyboard volume changes.

### Reliability and UI

- Reworked Multipoint and listening-mode menu views for macOS AppKit behavior.
- Removed cross-hierarchy Auto Layout activation failures.
- Added safety guards for unsupported or unverified protocol actions.
- Improved menu-bar recovery and menu persistence while changing settings.

### Validation

- Release build verified with `swift build -c release`.
- Installed-app launch verified with no fresh `NSGenericException`,
  `CoreAutoLayout`, or termination errors.
- XM6 logs verified for capability discovery, Multipoint state, connected-device
  slots, and playback-slot reporting.

### Not included

- Codec and firmware-version readout.
- DSEE Extreme.
- Adaptive Sound Control.
- Quick Access assignment.
- Dock application mode.
