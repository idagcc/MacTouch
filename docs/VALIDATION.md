# Development validation

Checked 31 October 2026 on an Apple silicon Mac running macOS 27.0.1, using the full Xcode Swift 6.4.2 toolchain. The target is macOS 13 or later; earlier OS versions and Intel execution have not been tested on hardware.

## Completed

- Native app compiles in debug and release configurations.
- **56 XCTest cases pass:** 39 HID parsing/frame-assembly cases, 12 coordinate/gesture cases, 2 end-to-end serial-contact-to-pointer cases and 3 touch-test measurement cases. The measurement cases check a brief three-contact frame followed by liftoff, disconnect without inventing a received frame, and reset. Tests use synthetic standards-based fixtures, not captured ASUS reports.
- Version 0.1.1 reproduces and fixes a standard serial-protocol bug: the second finger previously replaced the first in the decoded snapshot. The regression now verifies two contacts, scrolling, independent liftoff, reset and a subsequent click. A separate preview correction immediately publishes contact-ID changes even within a 33 ms UI update interval; this UI correction was reviewed in code.
- Universal release executable builds for `arm64` and `x86_64`. The Mach-O minimum OS is 13.0 for both architectures.
- App bundle is ad-hoc signed and its signature is verified. It is not Developer ID signed or notarized.
- Read-only `--diagnose` run launches, enumerates the current display, reports permission state, and exits successfully without pointer output. Subsequent discovery identified the connected Weida Hi-Tech CoolTouchR System controller (USB 2575:0401), with a standard 10-slot touch report on report ID 1.
- Running UI inspected: Connection page, empty-device state, live-preview placeholder, display selection, permission controls, Touch settings and Diagnostics. Missing-device controls are disabled, and no fake device data is shown.
- Static review checked callback ownership, composite USB identities, per-device decoder state, common-mode frame timers, cancellation, display/session changes and profile persistence. Identical ambiguous interfaces require reselection instead of sharing saved identity.
- MIT attribution and license for the adapted Touch-Up frame-assembly technique are included in the source and distribution bundle. No third-party executables or private gesture APIs are embedded.

## Local 0.1.2 hardware session — 31 October 2026

- Added **Touch tester → Sensor / Simulation**, with numbered contacts, normalized positions, current/peak counts and two-/three-contact milestones. The selected controller's measurements are updated before UI throttling. Simulation owns separate view state and never reaches the HID decoder, sensor statistics, diagnostics or pointer output. Pointer output pauses on entering the tester and requires a fresh liftoff after leaving it.
- Built and ad-hoc signed the universal 0.1.2 app. Verified the simulator controls at 3 and 10 points, liftoff to zero with the peak retained, peak reset, and independent dragging of contact 1 while contacts 2 and 3 retained their positions. Switching back to Sensor preserved the hardware peak rather than the simulated peak.
- The existing Input Monitoring entry appeared enabled, but the rebuilt app still reported denied access. With the user's explicit approval, removed/re-added the current app in Input Monitoring and used **Quit & Reopen**. The app then reported input access allowed. A locally rebuilt ad-hoc signed app may need this refresh.
- On the connected **CoolTouchR System, USB 2575:0401**, **Request multitouch mode** read Device Mode **0**, wrote the advertised standard setting, and verified readback **2**. No vendor-specific commands were sent.
- The user physically touched the sensor. The Sensor tester received **398 decoded hardware frames**, reached a **peak of 5 simultaneous contacts**, showed both the 2+ and 3+ milestones as seen, then returned to **0 contacts / All fingers lifted**. Later UI verification showed 608 sensor frames with the same peak. This verifies real multi-contact reception up to the observed peak on this controller and connection; ten simultaneous contacts were not physically tested.
- The sensor's video cable was disconnected. Its normalized touch surface was visible on the laptop's built-in display. Accessibility was still unapproved, and pointer output remained disabled; actual mouse injection, mapping accuracy and two-finger scrolling were not tested in this session.
- The exact monitor model remains unidentified. Reconnect defaults, mode persistence, sleep/wake and other controllers remain unverified.

## Required before claiming full ASUS compatibility

1. Record the exact ASUS model, USB vendor/product IDs, interface identities and report descriptor using **Export diagnostics** on the target Mac mini.
2. Verify reports arrive over the intended USB-A cable and USB-C adapter; test both a direct connection and the chosen adapter if needed.
3. Keep pointer control paused and verify Live Touch, including liftoff and two-finger frames. Only request standard multitouch mode if appropriate to the device.
4. Grant macOS permissions manually, map the touchscreen display, then verify corners, center, repeated clicks, double-clicks, drags and slow two-finger scrolling.
5. Test unplugging during a drag, incomplete frames, display removal, sleep/wake, session changes, revoked permissions and reconnects. Confirm every case releases the synthetic mouse button.
6. Install the final signed app in Applications, enable launch at login, sign out/in and verify quiet background startup. Check disabled startup, deliberate Quit and uninstall independently.
7. Test the signed/notarized build on a clean supported Mac. Measure latency, idle CPU and memory before setting performance claims.

Accessibility approval, actual mouse injection, logout/login and notarization were **not** exercised. Standard Device Mode writes and physical multi-contact reception were verified in the user-assisted session above. The login feature is implemented using Service Management; the current main-app registration does not provide crash supervision or pre-login input.
