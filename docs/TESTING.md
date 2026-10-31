# MacTouch 0.1.1 tester guide

Download [MacTouch.zip](https://github.com/idagcc/MacTouch/releases/download/v0.1.1/MacTouch.zip). This development preview targets macOS 13+ and contains both Apple silicon and Intel builds. Full multi-touch operation has not yet been verified on the intended ASUS monitor, and the app is not Apple-notarized.

## Retesting the one-point issue

Quit the old MacTouch from its menu-bar icon before replacing it in Applications. Open the new app and confirm the sidebar says **0.1.1**. Keep pointer control off, hold two fingers down, then move either finger: Live Touch should show two points, and its peak count should reach at least 2. Lift fingers individually and confirm the counts change from 2 to 1 to 0.

If only one point appears, use **Diagnostics → Request multitouch mode** and read the returned status. There is no need to rescan afterward. Test two fingers again. If it still shows one, export diagnostics and share the controller name, USB ID and exact ASUS model with the maintainer. The report now includes framing, observed contact counts and mode readback to distinguish a decoder issue from device configuration.

## Install and connect

1. Unzip the download and move **MacTouch.app** to **Applications** before granting permissions.
2. Connect the monitor's video cable and its separate USB touch/data cable. A USB-A touch cable can connect through a data-capable USB-C adapter.
3. Open MacTouch. If macOS blocks the download, follow your organisation's software policy; the app does not require disabling SIP, Gatekeeper or other platform protections. A signed/notarized deployment build is still pending.
4. In **Connection**, select the touchscreen controller and the actual touchscreen display. Allow **Pointer control** in macOS Accessibility. If reports do not arrive, allow **Input Monitoring**, quit/reopen the app and rescan.
5. Keep **Enable touch** off first. Touch the display and check that **Live Touch** shows your fingers and clears when you lift them.
6. Turn **Enable touch** on, then touch and lift once to arm the pointer. Test the centre and corners, clicks, double-clicks, dragging and two-finger scrolling.
7. In **Touch settings**, adjust rotation or flips only if positions are incorrect. Enable **Launch MacTouch at login** if you want it to start after sign-in.

Closing the window keeps MacTouch running. Its menu-bar icon provides **Pause touch** and **Quit MacTouch**. Keep your normal mouse/trackpad available while testing.

## What to check

- One finger clicks and drags on the chosen display, with no unexpected clicks on another display.
- Two fingers scroll, including slow movement. Adding a second finger ends an existing drag; lift all fingers before starting a new click.
- Unplugging USB during a drag releases the mouse button. Reconnecting, sleep/wake and display disconnects recover without a stuck drag.
- Closing the window preserves touch input. Enabling/disabling login startup produces the expected result after the next sign-in.
- A long stationary hold may be cancelled after ten seconds without reports. That is the current safety timeout.

Do not expect pinch/rotate, right-click, stylus pressure or login-screen/FileVault control in this version.

## Report results

Record the monitor model, Mac model, macOS version, cable/adapter, and the exact action that worked or failed. Use **Diagnostics → Export diagnostics** for controller IDs, descriptors and status. Review the file before sharing it; it contains device identifiers and display layout, but no keystrokes, serial numbers or touch history.

The repository is public during this test. Share diagnostic files directly with the maintainer if you do not want the hardware details posted publicly. No reports are uploaded automatically.

## Remove the preview

Turn off **Launch MacTouch at login**, quit MacTouch from its menu-bar icon, then move the app to Trash. Its macOS permissions can be removed in System Settings → Privacy & Security.
