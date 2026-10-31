# Development validation

Checked 31 October 2026 on an Apple silicon Mac running macOS 27.0.1, using the full Xcode Swift 6.4.2 toolchain. The target is macOS 13 or later; earlier OS versions and Intel execution have not been tested on hardware.

## Completed

- Native app compiles in debug and release configurations.
- **43 XCTest cases pass:** 31 HID parsing/frame-assembly cases and 12 coordinate/gesture cases. Tests use synthetic standards-based fixtures, not captured ASUS reports.
- Universal release executable builds for `arm64` and `x86_64`. The Mach-O minimum OS is 13.0 for both architectures.
- App bundle is ad-hoc signed and its signature is verified. It is not Developer ID signed or notarized.
- Read-only `--diagnose` run launches, enumerates the current display, reports permission state, and exits successfully without pointer output. No external touchscreen is attached on this development Mac.
- Running UI inspected: Connection page, empty-device state, live-preview placeholder, display selection, permission controls, Touch settings and Diagnostics. Missing-device controls are disabled, and no fake device data is shown.
- Static review checked callback ownership, composite USB identities, per-device decoder state, common-mode frame timers, cancellation, display/session changes and profile persistence. Identical ambiguous interfaces require reselection instead of sharing saved identity.
- MIT attribution and license for the adapted Touch-Up frame-assembly technique are included in the source and distribution bundle. No third-party executables or private gesture APIs are embedded.

## Required before claiming ASUS compatibility

1. Record the exact ASUS model, USB vendor/product IDs, interface identities and report descriptor using **Export diagnostics** on the target Mac mini.
2. Verify reports arrive over the intended USB-A cable and USB-C adapter; test both a direct connection and the chosen adapter if needed.
3. Keep pointer control paused and verify Live Touch, including liftoff and two-finger frames. Only request standard multitouch mode if appropriate to the device.
4. Grant macOS permissions manually, map the touchscreen display, then verify corners, center, repeated clicks, double-clicks, drags and slow two-finger scrolling.
5. Test unplugging during a drag, incomplete frames, display removal, sleep/wake, session changes, revoked permissions and reconnects. Confirm every case releases the synthetic mouse button.
6. Install the final signed app in Applications, enable launch at login, sign out/in and verify quiet background startup. Check disabled startup, deliberate Quit and uninstall independently.
7. Test the signed/notarized build on a clean supported Mac. Measure latency, idle CPU and memory before setting performance claims.

Accessibility approval, actual mouse injection, feature-mode writes, target hardware, logout/login and notarization were **not** exercised automatically. The login feature is implemented using Service Management; the current main-app registration does not provide crash supervision or pre-login input.
