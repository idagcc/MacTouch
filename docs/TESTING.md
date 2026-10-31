# MacTouch 0.1.2 tester guide

Download [MacTouch.zip](https://github.com/idagcc/MacTouch/releases/download/v0.1.2/MacTouch.zip). This development preview targets macOS 13+ and contains both Apple silicon and Intel builds. It is a macOS app and does not run on Windows. Physical input with five simultaneous contacts was verified on a CoolTouchR System controller (USB 2575:0401); pointer/scroll operation and other monitor models remain unverified. The app is not Apple-notarized.

## Test touch points on another Mac

1. Quit the old MacTouch from its menu-bar icon before replacing it in **Applications**. Open the new app and confirm the sidebar says **0.1.2**.
2. Connect the sensor's USB cable, open **Touch tester → Sensor**, and choose its controller. The sensor's video cable is not needed to show its surface on your Mac's display.
3. Enable MacTouch under **Privacy & Security → Input Monitoring**, then quit/reopen MacTouch. Accessibility is only needed later for cursor control.
4. If Input Monitoring already appears on but no sensor frames arrive after updating, remove the old MacTouch entry with **−**, add the current app from Applications with **+**, and choose **Quit & Reopen**. This refresh was necessary for the locally rebuilt ad-hoc signed app.
5. If touch only moves the cursor, no dots appear, or only one finger is reported, use **Request multitouch mode** in the tester or **Diagnostics**. On the tested CoolTouchR controller, mode **0 → 2** enabled separate contacts. Do not rescan after a confirmed mode change.
6. Hold one finger down, add a second and then a third, and move each. The numbered points should remain separate. Lift them individually and verify **3 → 2 → 1 → 0**. **Most together** should remain at least 3. **Reset peak** starts a fresh measurement, retaining any currently held fingers.
7. Use **Simulation** to try 1, 2, 3, 5 or 10 mouse-generated points, drag points independently, and use **Lift all**. This requires no sensor or permissions and does not count toward the sensor's measured peak.

Pointer control pauses while **Touch tester** is selected. Return to **Connection** before testing clicks or scrolling. A mode-2 readback alone does not prove physical multitouch; the sensor's measured peak is the relevant evidence. If it still shows one point or zero frames, export diagnostics and share the controller name, USB ID and exact monitor model. USB reconnects may restore the default controller mode; request multitouch mode again if needed.

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
