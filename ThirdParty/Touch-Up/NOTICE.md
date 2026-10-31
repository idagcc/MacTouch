# Touch-Up adaptation

The count/offset assembly algorithm in `Sources/MacTouchCore/HIDReportDecoder.swift`
is adapted into Swift from `StoreInputValue` and `DispatchTouches` in:

- Project: [Touch-Up](https://github.com/shueber/Touch-Up)
- Author: Sebastian Hueber
- License: MIT; reproduced in the adjacent `LICENSE` file
- Reviewed revision: `59a4fd28ae939dafb2f4ad9df9b00e959b40eada`
- [Original implementation](https://github.com/shueber/Touch-Up/blob/59a4fd28ae939dafb2f4ad9df9b00e959b40eada/TouchUpCore/HIDInterpreter.c)

The adaptation accumulates contacts from a nonzero initial Contact Count followed
by zero-count continuation packets and publishes only a completed frame. MacTouch
adds per-device value state, mandatory scan-time agreement for hybrid packets,
a 50 ms receive deadline, a 32-contact ceiling, identifier checks, and reset on
failure. Contact Count includes liftoff and rejected contacts, not just active
fingers. A silent device also requires the app's pointer watchdog; the decoder
checks its deadline when the next packet arrives.

The surrounding descriptor parser, validation, Swift types, and tests are local
implementations. No upstream IOKit queue implementation, feature-report writes,
pinch event fields, or other private event APIs are incorporated here.

Protocol references:

- [Microsoft: packet reporting modes](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/selecting-packet-reporting-modes-in-multitouch-drivers)
- [Microsoft: required touchscreen collections](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/touchscreen-required-hid-top-level-collections)

This adaptation does not establish support for a particular monitor model.
Hardware with hybrid packets that omit Scan Time, contact data spread across
different report IDs, or vendor-specific protocols still needs a device profile.
