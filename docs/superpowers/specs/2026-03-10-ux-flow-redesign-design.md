# UX Flow Redesign

## Overview

Redesign Pylo's user flow to add onboarding, consolidate camera selection, add a screen saver mode, and add an iOS Settings bundle. The Running/Config split is already implemented — RunningView presents a minimal black screen with a gear button that opens RunningConfigView as a full-screen cover (iOS) or sheet (macOS).

### Current state (already implemented)

- **RunningView**: Black screen with pixel-shift burn-in prevention, green status indicator, button tile (when enabled), gear button opening Config.
- **RunningConfigView**: Full-screen cover (iOS) / sheet (macOS) with "Settings" nav title, Save/Cancel toolbar, accessory cards + unpair button. Uses `ContentView(forceConfig: true)` for the card layout.
- **PairingView**: QR code + setup code, instruction text.
- **ContentView**: Navigation flow — network denied → pairing → running/config. Restart banner and "Updating Home" toast in safe area inset.
- **macOS support**: Platform-conditional UI throughout (`#if os(iOS)` / `#if os(macOS)`).

### Remaining work

- Welcome/onboarding screen
- Global camera picker (consolidate `selectedStreamCamera` + `sensorCamera`)
- General settings section in Config (camera, display, screen saver)
- Screen saver mode
- iOS Settings bundle

## Screen Flow

```mermaid
flowchart TD
    Launch --> HasSeenWelcome{Seen welcome?}
    HasSeenWelcome -->|No| Welcome
    HasSeenWelcome -->|Yes| HasPairings{Has pairings?}

    Welcome -->|"Get Started (triggers network permission on iOS)"| Pairing

    HasPairings -->|No| Pairing
    HasPairings -->|Yes| IsRunning{Server running?}

    Pairing -->|"Controller pairs via Home app"| IsRunning

    IsRunning -->|Yes| Running
    IsRunning -->|No, starting| Running

    Running -->|Gear button| Config
    Config -->|Done| Running
    Config -->|Unpair| Pairing

    NetworkDenied[Network Denied] -.->|"Shown instead of Pairing\nwhen network access denied"| Launch
```

## Screens

### 1. Welcome (shown once) — NEW

- Displayed on first launch only (persisted flag in UserDefaults).
- Brief overview: Pylo turns your device into a HomeKit bridge with native accessories.
- iOS: Key callout — "Pylo must remain in the foreground with the screen on to work."
- macOS: Omit the foreground callout (macOS runs as a background service without this constraint).
- "Get Started" button:
  - iOS: Triggers the local network permission prompt, then navigates to Pairing.
  - macOS: Navigates directly to Pairing (macOS does not have the same local network permission prompt).
- Not shown again after dismissal, even if the user unpairs later.

### 2. Pairing — EXISTS

Already implemented. No changes needed.

- QR code + setup code.
- Instruction text: "Scan with the Home app or enter the code manually."
- iOS: Subtle reminder at the bottom — "Keep Pylo in the foreground while in use."
- Server is auto-started and running during this screen.

### 3. Running — EXISTS

Already implemented. No changes needed.

- Minimal black screen with pixel-shift burn-in prevention.
- Green checkmark status indicator (top-left).
- Button tile when button accessory is enabled.
- Gear icon (top-right) opens Config.
  - iOS: Full-screen cover.
  - macOS: Sheet (min 480×500).

### 4. Config — EXISTS, NEEDS CHANGES

Currently shows accessory cards + unpair button in a flat list. Restructure into grouped sections:

#### General section (top) — NEW

| Setting | Control | Platform | Notes |
|---------|---------|----------|-------|
| Camera | Picker | Both | Single global selection used by all camera-dependent accessories |
| Keep Display On / Prevent Sleep | Toggle | Both | Label is "Keep Display On" (iOS) or "Prevent Sleep" (macOS) |
| Screen Saver | Toggle + delay picker | iOS only | Delay picker shown when enabled. See Screen Saver section below. |
| Unpair | Destructive button | Both | Confirmation dialog before executing. Not in Settings bundle. |

#### Accessories section (below) — MODIFY

Accessory cards as today with these changes:

- **Camera**: Remove camera picker (uses global). Keep quality, microphone, status.
- **Light Sensor**: Remove camera picker. Show read-only "Using: [camera name]" when relevant.
- **Occupancy Sensor**: Remove camera picker. Keep cooldown, status. Show read-only camera note.
- **All other cards**: Unchanged (button, flashlight, motion sensor, contact sensor, siren).

Camera-dependent accessory cards that would have shown a picker instead show a read-only line indicating which camera is in use.

The Keep Display On / Prevent Sleep card moves from the accessories section to General.

### 5. iOS Settings Bundle — NEW

iOS only. Mirrors the General section (excluding Unpair and Camera):

- Keep Display On
- Screen Saver enabled + delay

Camera selection is excluded — Settings bundles use static plists and cannot dynamically enumerate available cameras. Unpair is excluded because it is a destructive action requiring the in-app confirmation dialog.

Changes made in the iOS Settings app are picked up when the app returns to foreground via `scenePhase` observation.

## Behavioral Details

### Camera consolidation

The current codebase has two independent camera selections: `selectedStreamCamera` (for the camera/streaming accessory) and `sensorCamera` (for light sensor/occupancy when camera streaming is off). These are collapsed into a single global camera picker in the General section. All camera-dependent accessories use the same camera. The `sensorCamera` property and `ensureSensorCamera()` helper are removed.

When the global camera is set to `nil` (no camera selected), camera-dependent accessories are disabled. Enabling any camera-dependent accessory prompts camera permission and selects the default back camera if no camera is currently selected.

### Screen saver

iOS only. When enabled, RunningView dims the screen after the configured delay and shows a slow-moving clock or blank screen to prevent burn-in. This supplements the existing pixel-shift mechanism. On macOS, the OS handles screen saver behavior natively, so this setting is not exposed.

### Network denied

Unchanged. The existing `networkDeniedBody` is shown in place of Pairing/Running when local network access is denied. If the user denies network permission during "Get Started" on the Welcome screen, they proceed to Pairing and see the network denied state there (the welcome flag is still set — they don't see the welcome screen again).

### Camera/microphone permissions

Unchanged. Each accessory card requests the relevant permission (camera or microphone) when its toggle is enabled. If denied, the card shows a "Permission denied" blocked state with an alert offering to open Settings. The welcome screen does not request camera/microphone permissions.

### Restart banner

Unchanged. When accessory config diverges from the running server config, the "Restart to Apply" banner appears at the bottom of the Config view. The RunningConfigView toolbar shows Save (restarts) and Cancel (restores previous config). The banner does not appear on RunningView.

### Settings bundle and restart

iOS only. Changes made in the iOS Settings app are read on foreground return. If a Settings bundle change affects the running server config, it triggers the same `needsRestart` comparison, and the banner appears next time the user opens Config.

### Backgrounding

Unchanged. The app does not show a warning on return from background. The RunningView's screen-dimming/pixel-shift handles the "always on" use case on iOS.

### Unpair

Unchanged. Unpair stops the server, clears all pairings, and returns to the Pairing screen where the server restarts with a fresh setup code.

## Platform Considerations

| Aspect | iOS | macOS |
|--------|-----|-------|
| Config presentation | `fullScreenCover` | `sheet` (min 480×500) |
| Display setting label | "Keep Display On" | "Prevent Sleep" |
| Screen saver setting | Shown | Hidden (OS handles it) |
| Settings bundle | Yes | No (use in-app config) |
| Welcome foreground callout | Shown | Hidden |
| Network permission prompt | Triggered by "Get Started" | Not applicable |
| Haptic feedback (button) | `UIImpactFeedbackGenerator` | None |
| Card background | `UIColor.secondarySystemGroupedBackground` | `NSColor.controlBackgroundColor` |

## Key Decisions

- **Welcome shown once ever**, not on every unpaired launch. Prevents annoyance if user unpairs/re-pairs.
- **"Get Started" triggers network permission** (iOS) proactively rather than waiting for implicit server start failure.
- **Single global camera picker** in General settings, not per-accessory. Reduces duplication and confusion. All camera-dependent accessories share one camera.
- **Settings in config view** rather than a separate view. Keeps navigation simple (one gear button on RunningView).
- **Settings bundle is iOS-only** and limited to static options (display, screen saver). Camera selection excluded due to static plist limitation. Destructive actions (unpair) remain in-app only.
- **Screen saver is iOS-only**. macOS has native screen saver support.
