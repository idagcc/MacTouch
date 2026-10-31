# MacTouch

A native macOS menu-bar app that translates compatible external touchscreen input into mouse clicks, dragging and two-finger scrolling. Designed for an ASUS 22-inch touchscreen connected to a Mac mini using a USB-A cable and a USB-C data adapter. The exact ASUS model and its hardware compatibility are **not yet verified**.

This is a working development preview, not a universal replacement for UPDD. It contains real HID discovery, report decoding and Quartz output; the empty device list on a Mac without a touchscreen is intentional.

**Test build:** [Download MacTouch v0.1.3 for Apple silicon and Intel](https://github.com/idagcc/MacTouch/releases/download/v0.1.3/MacTouch.zip). See the [release notes](https://github.com/idagcc/MacTouch/releases/tag/v0.1.3) and [tester guide](docs/TESTING.md) before testing.

Version 0.1.1 fixed serial touchscreen reports replacing one held finger with another, and a preview refresh bug that could hide a rapidly added second finger. Those fixes remain included.

Version **0.1.2** adds a touch tester and mouse-driven simulator. A user-assisted test on the connected **CoolTouchR System (2575:0401)** received real sensor reports with **five simultaneous contacts**, after enabling Input Monitoring and requesting standard multitouch mode (0 → 2). This verifies multi-contact reception on that controller; full pointer/scroll behavior and the exact monitor model remain unverified. See the [hardware session notes](docs/VALIDATION.md).

Version **0.1.3** adds opt-in **pinch zoom for embedded maps**. With that setting enabled, the user confirmed that a physical pinch zoomed the actual Google Maps iframe in Safari in both directions. It uses Command + scroll over the mapped pinch midpoint; it does not synthesize native trackpad magnification.

## Try the app

1. Download the release ZIP (or build `dist/MacTouch.zip` locally), unzip it on the target Mac, and move **MacTouch.app** into **Applications** before granting permissions.
2. Connect video separately (for example, HDMI). Connect the monitor's upstream USB touch cable to the Mac mini through a data-capable USB-C to USB-A adapter. A video picture alone does not establish a touch connection.
3. Open MacTouch. In **Connection**, choose the detected touch controller and the actual touchscreen display.
4. Allow **Pointer control** in macOS Accessibility. If touch reports do not arrive, allow **Input Monitoring**, quit/reopen MacTouch, and rescan.
5. Open **Touch tester → Sensor** and confirm numbered dots appear. This also works with only the sensor's USB cable connected, showing its surface on the selected Mac display. If touching only moves the cursor, use **Request multitouch mode** in the tester or Diagnostics, then check for separate contacts without rescanning.
6. Return to **Connection** and turn on **Enable touch**. Touch and lift once to arm the pointer, then tap, drag or scroll with two fingers. Pointer output pauses while the tester is open.
7. In **Touch settings**, enable **Launch MacTouch at login**. Closing the window keeps the bridge running in the menu bar. Use the menu-bar icon to pause, reopen or quit.

The local build is ad-hoc signed, not Apple-notarized. Production distribution needs your Developer ID identity and notarization. A clean Mac may block this development build under its normal security policy; use your own signed build for deployment rather than disabling platform protections.

If no controller appears, check the USB upstream cable, adapter, monitor power and monitor touch setting. Confirm the exact model printed on the ASUS label; VT229H is only a candidate. See [ASUS's connection instructions](https://rog.asus.com/us/support/faq/1047313/).

If only one point appears with two fingers down, **Diagnostics → Request multitouch mode** can request the standard advertised HID Device Mode feature on the selected controller. It pauses pointer control, checks the feature's type/range, reads the current mode and verifies it after writing. It does not send guessed vendor commands. Check the Sensor tester without rescanning; rescanning is unnecessary and can reset some devices. Mode 0 → 2 was verified on the connected CoolTouchR System, followed by a physical five-contact peak. A reported mode of 2 alone confirms mode readback rather than multi-contact operation on another controller.

When updating an ad-hoc signed build, Input Monitoring may appear enabled while the new build still cannot read input. Remove its old entry, add the current **MacTouch.app** from Applications, then choose **Quit & Reopen**. See the [tester guide](docs/TESTING.md).

## Implemented

- **Embedded-map pinch zoom:** opt in with **Touch settings → Pinch zoom for embedded maps**. Finger separation becomes Command-modified pixel-wheel input at the mapped midpoint, using Google Maps' [documented zoom input](https://developers.google.com/maps/documentation/javascript/interaction). Moving fingers together remains scrolling; lift both before changing gesture. This is map input translation, not native trackpad magnification or Safari page zoom. The Sensor tester includes a pinch/scroll detector preview without sending output.
- **Touch tester:** a large contact map with numbered, color-coded fingers, coordinates, current/peak counts, and two-/three-finger milestones. Open **Touch tester → Sensor** to measure the selected USB controller without controlling the pointer. Only Input Monitoring is needed for this view; its video cable and Accessibility permission are not required. **Simulation** lets you create 1, 2, 3, 5 or 10 points and drag them with your mouse without permissions. Simulation stays separate from sensor measurements and diagnostics. Reset peak starts new measurements for the selected controller.
- Native SwiftUI setup window and menu-bar controls; no Dock icon required.
- macOS 13+ login startup through `SMAppService.mainApp`.
- Touchscreen-only HID matching; keyboard and ordinary mouse input are not captured.
- Per-interface report parsing with report IDs, packed fields, signed coordinate ranges, nested finger collections, confidence and contact IDs.
- Standard serial contact updates retain every contact ID until it lifts. Complete-frame single/parallel touch and bounded hybrid-frame assembly are also supported when required metadata is available.
- One selected touch controller mapped to one selected display; global display coordinates handle negative origins and Retina layouts.
- Rotation, axis flips, scroll speed and saved profiles. USB interface identity distinguishes composite devices. If stable identity is unavailable, reconnect requires reselection.
- Click/double-click, drag and two-finger scrolling. Additional fingers suppress output until all lift.
- Release/cancel on pause, disconnect, display changes, sleep, user-session changes, malformed input and permission revocation.
- Live touch preview updates immediately when fingers are added or removed. Local JSON diagnostics include current/peak contact counts, report IDs/framing, mode request/readback, controller descriptors, display layout and permissions. No serial numbers, keystrokes, touch history or network telemetry are collected.

## Current limits

- Full ASUS multi-touch compatibility remains unverified. A valid descriptor does not prove end-to-end compatibility. Export diagnostics from the target Mac for the next hardware-support pass.
- Proprietary/non-HID USB controllers, devices requiring vendor activation, ambiguous hybrid/serial layouts and mouse-emulation-only touch interfaces need dedicated profiles.
- Mouse and scroll translation is not native system-wide multitouch. Optional map pinch zoom requires a map that handles Command + scroll at the pointer location; native trackpad magnification, rotation, pressure, stylus handling, right-click and application-specific touch APIs are not implemented.
- Immediate mouse-down makes dragging responsive; adding a second finger releases that button before scrolling. It can trigger an initial primary click if the second finger arrives later.
- A ten-second gap in reports with active contacts releases input, clears cached serial contacts and requires a full lift. This also clears stale Live Touch state while pointer control is paused. A controller that reports only changes can therefore have a legitimate long stationary hold cancelled.
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
