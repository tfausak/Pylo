# Doorbell Feature Design

Resolves #23 and #24.

## Overview

Add a doorbell accessory to Pylo. A large on-screen button triggers a HomeKit doorbell notification with camera snapshot. This requires a new "running" screen that replaces the current screen saver, with config access behind a gear icon compatible with iOS Guided Access.

## UI Architecture

Three states in `ContentView`:

1. **Not paired / Network denied** — unchanged (pairing view, network error)
2. **Paired, running** — new `RunningView`
3. **Paired, not running** — config cards (current `pairedBody`; brief state since server auto-starts)

### RunningView

Shown when `isRunning && hasPairings`. Layout:

- Near-empty dark screen
- Small status indicator (green dot + "Running") top-center
- Small gear icon in one corner — presents config as `.fullScreenCover`
- When doorbell enabled: large circular doorbell button, centered
- When doorbell disabled: just the status indicator and gear
- Entire view content pixel-shifts every ~60 seconds by 1-3px in a random direction (burn-in prevention)

### Config Access

Gear icon opens current config card list (plus a new Doorbell card). Dismiss returns to running view. Full-screen cover provides clean modal separation without navigation stack complexity.

### Guided Access

- User circles the gear icon area in Guided Access to block visitor access
- Doorbell button remains functional — no special code needed
- No in-app guidance about Guided Access setup (keep it simple)

## Doorbell Button

**Appearance:**
- Large circle (~150pt diameter), centered on screen
- Doorbell icon inside (SF Symbol `bell.fill` or similar)
- Subtle border or fill — visible but not aggressively bright (OLED longevity)

**Interaction:**
- Tap triggers `ProgrammableSwitchEvent` notification to HomeKit
- Brief visual feedback — button pulses or flashes on press
- 2-second cooldown after ring — button visually dimmed/grayed, ignores taps
- Haptic feedback on successful ring

## Screen Saver Removal

The running view replaces the screen saver. Pixel shifting handles burn-in prevention.

**Remove:**
- `screenSaverEnabled` and `screenSaverDelay` from `HAPViewModel`
- Their `UserDefaults` persistence
- `isScreenDimmed`, `dimTask`, `isDimTimerResetPending` state in `ContentView`
- Full-black `Color.black` overlay
- `resetDimTimer()` and all call sites
- Screen saver toggle and delay picker from Display `AccessoryCard`
- Display `AccessoryCard` itself (move "Keep Display On" to a simpler toggle or standalone card)

**Keep:**
- `keepScreenAwake` toggle and `isIdleTimerDisabled` logic — unchanged

**Add:**
- Pixel-shift timer in `RunningView` — offsets content by small random amount every ~60 seconds

## HAP Doorbell Service

**Service:**
- Doorbell service UUID `0x121`, attached as additional service on existing `HAPCameraAccessory`
- Not a separate accessory — shares the camera's accessory ID

**Characteristics:**
- `ProgrammableSwitchEvent` (UUID `0x73`, format `UInt8`, event-only)
- Null on read, sends `0` ("single press") on ring
- `Mute` and `Volume` skipped — not required by HAP spec for basic doorbell

**Wiring:**
- `HAPCameraAccessory` gains optional doorbell service (added when doorbell enabled)
- Button tap in `RunningView` → closure on view model → `notifySubscribers` for `ProgrammableSwitchEvent`
- HomeKit controllers receive event → show doorbell notification with camera snapshot

**Config:**
- New `doorbellEnabled` property in `HAPViewModel` (persisted to `UserDefaults`)
- Added to `AccessoryConfig` — enable/disable triggers server restart (changes service list)
- New "Doorbell" `AccessoryCard` in config, gated on camera being enabled

## Navigation Flow

```
ContentView
  ├── Network denied → networkDeniedBody (unchanged)
  ├── Not paired → PairingView (unchanged)
  ├── Paired + running → RunningView
  │     ├── Status indicator
  │     ├── Doorbell button (when enabled)
  │     └── Gear icon → .fullScreenCover → Config cards
  └── Paired + not running → Config cards (pairedBody)
```
