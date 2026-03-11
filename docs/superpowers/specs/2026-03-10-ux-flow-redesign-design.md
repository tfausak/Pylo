# UX Flow Redesign

## Overview

Redesign Pylo's user flow to add onboarding, separate status from configuration, consolidate camera selection, and add an iOS Settings bundle. Builds on the `doorbell` branch (PR #48) which already separates RunningView from ConfigView.

## Screen Flow

```mermaid
flowchart TD
    Launch --> HasSeenWelcome{Seen welcome?}
    HasSeenWelcome -->|No| Welcome
    HasSeenWelcome -->|Yes| HasPairings{Has pairings?}

    Welcome -->|"Get Started (triggers network permission)"| Pairing

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

### 1. Welcome (shown once)

- Displayed on first launch only (persisted flag in UserDefaults).
- Brief overview: Pylo turns your device into a HomeKit bridge with native accessories.
- Key callout: "Pylo must remain in the foreground with the screen on to work."
- "Get Started" button triggers the local network permission prompt, then navigates to Pairing.
- Not shown again after dismissal, even if the user unpairs later.

### 2. Pairing

- QR code + setup code (existing behavior).
- Instruction text: "Scan with the Home app or enter the code manually" (existing).
- Subtle reminder at the bottom: "Keep Pylo in the foreground while in use."
- Server is auto-started and running during this screen.

### 3. Running

- Minimal black screen with pixel-shift burn-in prevention (from doorbell branch).
- "Running" status indicator.
- Doorbell/button tile when button accessory is enabled (from doorbell branch).
- Gear icon in top-right opens Config as a full-screen cover.

### 4. Config (full-screen cover)

Grouped scrollable view with section headers. "Settings" nav title. "Done" button in toolbar dismisses back to Running.

#### General section (top)

| Setting | Control | Notes |
|---------|---------|-------|
| Camera | Picker | Single global selection used by all camera-dependent accessories |
| Keep Display On | Toggle | |
| Screen Saver | Toggle + delay picker | Delay picker shown when enabled |
| Unpair | Destructive button | Confirmation dialog before executing. Not in Settings bundle. |

#### Accessories section (below)

Accessory cards as today with these changes:

- **Camera**: Removes camera picker (uses global). Keeps quality, microphone, status.
- **Light Sensor**: Removes camera picker. Shows read-only "Using: [camera name]" when relevant.
- **Occupancy Sensor**: Removes camera picker. Keeps cooldown, status. Shows read-only camera note.
- **All other cards**: Unchanged (button, flashlight, motion sensor, contact sensor, siren).

Camera-dependent accessory cards that would have shown a picker instead show a read-only line indicating which camera is in use.

### 5. iOS Settings Bundle

Mirrors the General section (excluding Unpair):

- Camera selection
- Keep Display On
- Screen Saver enabled + delay

Changes made in the iOS Settings app are picked up when the app returns to foreground via `scenePhase` observation. Unpair is excluded because it is a destructive action requiring the in-app confirmation dialog.

## Key Decisions

- **Welcome shown once ever**, not on every unpaired launch. Prevents annoyance if user unpairs/re-pairs.
- **"Get Started" triggers network permission** proactively rather than waiting for implicit server start failure.
- **Single global camera picker** in General settings, not per-accessory. Reduces duplication and confusion.
- **Settings in config view** rather than a separate view. Keeps navigation simple (one gear button on RunningView).
- **Settings bundle mirrors in-app settings** so users can configure without opening the app, but destructive actions (unpair) remain in-app only.
