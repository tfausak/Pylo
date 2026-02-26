# Pylo Code Review — Burn Down List

## Correctness Issues

- [ ] **Thread safety across the board** — Pervasive data races: `HAPServer.notifySubscribers` called from `@MainActor` but iterates `connections` mutated on server's `DispatchQueue`; `EncryptionContext` counters incremented without synchronization; `MotionMonitor.isMotionDetected`/`lastMotionDate` accessed from `OperationQueue` and `@MainActor`; `PairingStore` accessed from server queue and `@MainActor`; `CameraStreamSession` properties accessed from `captureQueue`, `rtpQueue`, and calling thread.
- [ ] **Snapshot capture blocks the server** (`HAPCameraAccessory.swift:654`) — `captureSnapshot` uses `DispatchSemaphore.wait(timeout: 3)` on the server's dispatch queue, blocking all connection handling for up to 3 seconds.
- [x] **Screen brightness not restored on crash** (`PyloApp.swift:365`) — Burn-in prevention sets `UIScreen.main.brightness = 0`; if the app crashes while dimmed, the screen stays black. Persist `savedBrightness` to `UserDefaults`.
- [x] **Setup code doesn't exclude invalid codes** (`PairSetup.swift:25-28`) — HAP spec Table 5-8 requires excluding `000-00-000`, `111-11-111` through `999-99-999`, `123-45-678`, `876-54-321`.
- [ ] **No pair-setup rate limiting** (`PairSetup.swift:93-100`) — HAP spec section 5.6.1 requires a 30-second throttle after 100 failed attempts to prevent brute-force attacks on the 8-digit code.
- [x] **Unbounded buffer growth** (`HAPConnection.swift:64-67`) — `receiveBuffer` and `decryptedBuffer` grow without limit if a client sends data that never forms a complete HTTP request. Cap at a reasonable size (e.g. 1MB) and disconnect.
- [ ] **Camera usage description conflict** — `Info.plist` says "estimate ambient light levels" but `INFOPLIST_KEY_NSCameraUsageDescription` build setting says "Used to control the flashlight." The build setting wins; user sees the wrong description.

## Idiomatic Swift Issues

- [ ] **Use `@Observable` instead of `ObservableObject`** (`PyloApp.swift:50`) — `@Observable` macro is more performant (only invalidates views that read changed properties) and simpler.
- [ ] **Decompose `HAPCameraAccessory.swift` (~2100 lines)** — `CameraStreamSession` alone is ~1200 lines handling capture, H.264, RTP, SRTP, audio encode/decode, BSD sockets, and RTCP. Should be separate types.
- [x] **Deduplicate `toJSON` Accessory Information boilerplate** — The Accessory Information service JSON is copy-pasted across all 5 accessory classes. Extract to a shared helper or protocol extension.
- [ ] **Deduplicate RTCP sender report construction** (`HAPCameraAccessory.swift:1499-1550` and `1823-1868`) — Nearly identical 50-line blocks. Extract a shared function parameterized by SSRC, timestamp, packet/octet counts.
- [ ] **Replace `objc_setAssociatedObject` for delegate retention** (`HAPCameraAccessory.swift:1190, 1200`) — Store delegates as regular properties on `CameraStreamSession` instead of ObjC associated objects.
- [ ] **Replace magic number IIDs with named constants** — Callbacks use bare numbers like `iid == 9` (`PyloApp.swift:156`) and `iid == 14` (`PyloApp.swift:187`). Reference named constants from the accessory classes.
- [x] **Fix logger subsystem** — All loggers use `"com.example.hap"`. Should use `"me.fausak.taylor.Pylo"`.
- [ ] **Type-safe characteristic values** — `HAPAccessoryProtocol` uses `Any` for `readCharacteristic`/`writeCharacteristic`. A `HAPValue` enum would provide type safety.

## App Store Review Risks

- [ ] **Unauthorized HAP implementation** — App advertises `_hap._tcp` and implements HomeKit Accessory Protocol. Apple's MFi Program requires licensing for HAP accessories. Risk of rejection under Guidelines 5.2.1 (proprietary protocols) and 2.5.1 (public APIs).
- [ ] **No background mode declarations** — No `UIBackgroundModes`. Server, camera, and streaming all stop when backgrounded. Limits utility for an always-available HomeKit accessory.
- [ ] **No privacy manifest (`PrivacyInfo.xcprivacy`)** — iOS 17+ requires privacy manifests for apps using `UserDefaults`, file system APIs, `identifierForVendor`. App Store Connect will warn/reject without one.
- [ ] **`isIdleTimerDisabled` usage** (`PyloApp.swift:274`) — Preventing screen sleep is scrutinized under Guideline 2.5.4. Unusual for a "bridge" app.
- [ ] **`UIScreen.main.brightness` manipulation** (`PyloApp.swift:365`) — Setting system brightness to 0 is aggressive. If the app is killed in this state, the user's screen stays black.

## Other

- [ ] Allow turning accessories off entirely. For example selecting "None" as the camera for the light sensor should disable the light sensor completely.
