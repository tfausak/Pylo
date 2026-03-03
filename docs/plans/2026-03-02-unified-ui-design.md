# Unified UI Design

## Overview

Replace the current multi-screen UI (ConfigureView, DashboardView, SettingsView sheet) with a single unified screen. The server auto-starts on launch. Two app states: unpaired (full-screen QR code) and paired (accessory widget list).

## App States

### Unpaired (no pairings)

Full-screen pairing view:
- Header: "Pylo" left-aligned, status icon + label far right (e.g. bolt.fill + "Starting", checkmark.circle.fill + "Running")
- Centered QR code (200x200, pixel-perfect interpolation)
- Setup code in monospaced bold
- Instruction text: "Scan with the Home app or enter the code manually"
- Transitions to paired state live when `hasPairings` becomes true

### Paired

Unified main screen with three zones:

**Header:** "Pylo" bold left, tappable status indicator far right. Tapping status opens a menu with "Unpair" (confirmation alert before executing `resetPairings()`). No stop server option.

**Body:** Scrollable list of accessory cards:

1. **Camera** — toggle enables/disables. Expanded: streaming status, camera picker (dropdown), quality picker (segmented).
2. **Flashlight** — toggle enables/disables. Expanded: on/off and brightness status. No config options.
3. **Motion Sensor** — toggle enables/disables. Expanded: motion detected status, sensitivity picker (segmented).
4. **Display** — toggle enables keep-screen-awake. Expanded: screen saver toggle, delay picker. Does not affect `needsRestart`.

Each card:
- Collapsed (toggle off): icon, name, toggle. That's it.
- Expanded (toggle on): icon, name, toggle, separator, status line, inline config options.
- Animated expand/collapse transition.
- Subtle background (`.quaternary` or similar), rounded corners.

**Footer:** Sticky "Restart to Apply" button via `safeAreaInset(.bottom)`, visible only when `needsRestart == true`. Prominent filled style, orange/accent tint. Triggers `viewModel.restart()`.

## Screen Dimming

Screen dimming overlay (for keep-screen-awake + screen-saver mode) stays in ContentView as local @State, same as current behavior.

## File Changes

- **Delete:** `ConfigureView.swift`, `SettingsView.swift`, `DashboardView.swift`
- **Rewrite:** `ContentView.swift` — single root view with unpaired/paired states
- **New:** `AccessoryCard.swift` — reusable expand/collapse card component
- **Modify:** `HAPViewModel.swift` — auto-start on init/appear, `stop()` becomes internal (only used by `restart()` and `resetPairings()`), `isStarting` becomes internal state
- **Modify:** `PyloApp.swift` — trigger auto-start on appear
- **Update:** `PairingView.swift` — match new header style

## ViewModel Changes

- Server auto-starts on app launch (no manual Start button)
- `isStarting` no longer user-facing; header shows "Starting" vs "Running" based on `isRunning`
- `stop()` is internal — only called by `restart()` and during unpair flow
- All accessory toggle/config state unchanged — same @Observable properties, same UserDefaults persistence
- `needsRestart` computed property unchanged
