# MacTouch

A native macOS menu-bar app that translates compatible external touchscreen input into mouse clicks, dragging and two-finger scrolling. Designed for an ASUS 22-inch touchscreen connected to a Mac mini using a USB-A cable and a USB-C data adapter. The exact ASUS model and its hardware compatibility are **not yet verified**.

This is a working development preview, not a universal replacement for UPDD. It contains real HID discovery, report decoding and Quartz output; the empty device list on a Mac without a touchscreen is intentional.

**Test build:** [Download MacTouch v0.1.0 for Apple silicon and Intel](https://github.com/idagcc/MacTouch/releases/download/v0.1.0/MacTouch.zip). See the [release notes](https://github.com/idagcc/MacTouch/releases/tag/v0.1.0) and [tester guide](docs/TESTING.md) before testing.

## Try the app

1. Download the release ZIP (or build `dist/MacTouch.zip` locally), unzip it on the target Mac, and move **MacTouch.app** into **Applications** before granting permissions.
2. Connect video separately (for example, HDMI). Connect the monitor's upstream USB touch cable to the Mac mini through a data-capable USB-C to USB-A adapter. A video picture alone does not establish a touch connection.
3. Open MacTouch. In **Connection**, choose the detected touch controller and the actual touchscreen display.
4. Allow **Pointer control** in macOS Accessibility. If touch reports do not arrive, allow **Input Monitoring**, quit/reopen MacTouch, and rescan.
5. Touch the monitor while **Enable touch** is off. Confirm dots appear in **Live Touch**.
6. Turn on **Enable touch**. Touch and lift once to arm the pointer, then tap, drag or scroll with two fingers.
7. In **Touch settings**, enable **Launch MacTouch at login**. Closing the window keeps the bridge running in the menu bar. Use the menu-bar icon to pause, reopen or quit.

The local build is ad-hoc signed, not Apple-notarized. Production distribution needs your Developer ID identity and notarization. A clean Mac may block this development build under its normal security policy; use your own signed build for deployment rather than disabling platform protections.

If no controller appears, check the USB upstream cable, adapter, monitor power and monitor touch setting. Confirm the exact model printed on the ASUS label; VT229H is only a candidate. See [ASUS's connection instructions](https://rog.asus.com/us/support/faq/1047313/).

If only mouse-like input appears, **Diagnostics → Request multitouch mode** can request the standard advertised HID Device Mode feature on the selected controller. It pauses pointer control and checks the feature's type/range before writing. It does not send guessed vendor commands. Rescan afterward and verify real reports. This option has not yet been tested on the user's ASUS monitor.

## Implemented

- Native SwiftUI setup window and menu-bar controls; no Dock icon required.
- macOS 13+ login startup through `SMAppService.mainApp`.
- Touchscreen-only HID matching; keyboard and ordinary mouse input are not captured.
- Per-interface report parsing with report IDs, packed fields, signed coordinate ranges, nested finger collections, confidence and contact IDs.
- Complete-frame single/parallel touch and bounded hybrid-frame assembly when required metadata is available.
- One selected touch controller mapped to one selected display; global display coordinates handle negative origins and Retina layouts.
- Rotation, axis flips, scroll speed and saved profiles. USB interface identity distinguishes composite devices. If stable identity is unavailable, reconnect requires reselection.
- Click/double-click, drag and two-finger scrolling. Additional fingers suppress output until all lift.
- Release/cancel on pause, disconnect, display changes, sleep, user-session changes, malformed input and permission revocation.
- Live touch preview and local JSON diagnostics containing controller IDs/descriptors, display layout and permission status. No serial numbers, keystrokes, touch history or network telemetry are collected.

## Current limits

- No ASUS monitor has been tested yet. A valid descriptor does not prove end-to-end compatibility. Export diagnostics from the target Mac for the next hardware-support pass.
- Proprietary/non-HID USB controllers, devices requiring vendor activation, ambiguous hybrid/serial layouts and mouse-emulation-only touch interfaces need dedicated profiles.
- Mouse and scroll translation is not native system-wide multitouch. Pinch/rotate, pressure, stylus handling, right-click and application-specific touch APIs are not implemented.
- Immediate mouse-down makes dragging responsive; adding a second finger releases that button before scrolling. It can trigger an initial primary click if the second finger arrives later.
- A ten-second gap in reports during an active gesture releases input and requires a full lift. A controller that reports only changes can therefore have a legitimate long stationary hold cancelled.
- Login startup occurs after user sign-in. It does not enable FileVault/login-screen touch and does not guarantee restart after a crash. Login registration is implemented but a real logout/login cycle is not automated by the development tests.
- No DriverKit extension, root daemon, calibration wizard, installer/updater or notarized distribution yet.

## Build and test

Use full Xcode for XCTest. The scripts prefer `/Applications/Xcode.app` when installed without changing the system's selected developer tools. There are no third-party package downloads or runtime dependencies.

```sh
./scripts/test.sh
./scripts/build-app.sh             # current Mac architecture
./scripts/build-app.sh --universal # Apple silicon + Intel
open dist/MacTouch.app --args --show
```

For a signed production candidate, supply your own installed signing identity:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh --universal
```

Then notarize the archive using your configured Apple credentials and staple the accepted ticket before distributing. The build script preserves a stable bundle identifier, adds the icon and third-party notices, verifies the signature, and creates the transfer archive. It does not upload or publish the app.

Read-only discovery smoke test (does not enable pointer output or change launch-at-login):

```sh
dist/MacTouch.app/Contents/MacOS/MacTouch --diagnose
```

The tests exercise malformed/truncated descriptors, packed fields, report IDs, contact state, frame assembly, coordinate transforms, gesture transitions and cancellation. They do not grant permissions or move the real pointer. See [validation notes](docs/VALIDATION.md) for the actual checks performed and pending hardware work.

## Design and open-source research

- [Platform research](docs/RESEARCH.md): Apple/USB/ASUS sources, implementation choices, driver boundaries and hardware acceptance plan.
- [Open-source comparison](docs/OPEN_SOURCE.md): ten repositories, pinned revisions, licences, maintenance and reuse recommendations.
- [Third-party notices](ThirdParty/Touch-Up/NOTICE.md): Touch-Up's MIT hybrid-frame approach adapted into the Swift decoder.

`MacTouchCore` contains deterministic report parsing and gesture decisions. `MacTouchApp` owns hardware discovery, permissions, event posting, profiles, login registration and UI. No undocumented gesture event fields or private multitouch frameworks are used.
