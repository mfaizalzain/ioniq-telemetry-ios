# IONIQ Telemetry (iOS)

Live 800 V battery telemetry, automatic drive logging and battery-aware charge-stop
planning for E-GMP electric cars (Hyundai IONIQ 5/6, Kia EV6/EV9, Genesis GV60),
read over a Bluetooth or WiFi OBD-II adapter.

Native SwiftUI app, iPhone only, iOS 17+. It is a port of the Android build and
deliberately shares its data formats — the backup file and the AI prompt fixtures are
byte-identical across platforms and are asserted as such by tests on both sides.

---

## Requirements

| | |
|---|---|
| Deployment target | iOS 17.0 (`TARGETED_DEVICE_FAMILY = 1`, iPhone only) |
| Language / toolchain | Swift 6.0, Xcode 16 |
| Project generation | [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source of truth |
| Bundle ID | `com.fmz.IoniqTelemetry` |
| Hardware | ELM327-compatible OBD-II adapter (BLE or WiFi) |

## Build and run

```bash
brew install xcodegen
cp Secrets.xcconfig.example Secrets.xcconfig   # gitignored; fill in if you have an OCM key
xcodegen generate
open IoniqTelemetry.xcodeproj
```

Helper scripts:

| Script | What it does |
|---|---|
| `scripts/run_device.sh [--carplay]` | Build, install and launch on a connected iPhone |
| `scripts/run_carplay_sim.sh` | Simulator build with the CarPlay entitlement, for the CarPlay display |
| `scripts/archive_and_upload.sh [--no-upload]` | Release archive → TestFlight |
| `scripts/generate_icons.py` | Regenerate the app icon set from `store_assets/logo_source.png` |

Tests are Swift Testing suites in the packages and run without the app target:

```bash
swift test --package-path Packages/CoreDomain
swift test --package-path Packages/CoreData
swift test --package-path Packages/CoreOBD
swift test --package-path Packages/CoreRouting
```

### Build configurations

`Debug`, `Debug-CarPlay` and `Release`. `Debug-CarPlay` exists only so the CarPlay
entitlement can be applied without making it the default — passing
`CODE_SIGN_ENTITLEMENTS` on the `xcodebuild` command line leaks into every SPM package
target and the app target's own setting wins anyway. `Release` carries the CarPlay
entitlement.

The `IoniqTelemetry` scheme runs against `Resources/IoniqTelemetry.storekit`, so the
paywall is exercisable before the product exists in App Store Connect.

## Module layout

```
IoniqTelemetry/          app target — SwiftUI screens, CarPlay scene, drive service
  App/                   composition root (AppServices), root view, app entry
  UI/                    Dashboard, Trips, Plan, Settings, Paywall
  Service/               ConnectedCarService, VehicleLocationProvider, AlertNotifier
  Services/AiService     Gemini / DeepSeek clients
  CarPlay/               template stack and coordinator
Packages/
  CoreDomain             models, monitors, prompt templates, repository protocols (no deps)
  CoreOBD                transports, ELM327 init, ISO-TP, polling, decoder, vehicle profiles
  CoreData               SwiftData entities, repositories, network layer, backup
  CoreRouting            trip solver, charge curve, consumption model, live replan
  CoreUI                 theme, typography, shared components
```

Dependencies point one way: `CoreDomain` ← everything, `CoreData`/`CoreOBD`/`CoreRouting`
→ `CoreDomain` only. The app target composes them in `AppServices`.

---

## Features

### Live telemetry
- BMS state of charge and display SOC, BMS-reported SOH, pack voltage/current and
  derived power, cell min/max and delta in mV, per-module pack temperatures, inlet
  and ambient/cabin temperature, speed, odometer, 12 V auxiliary voltage, TPMS
  pressures and temperatures.
- Charging detection with AC/DC type, and a DC charge-curve chart on the dashboard.
- Range estimate labelled by provenance: `measured` from the driver's own logged
  trips, or `nominal` (18 kWh/100 km E-GMP default) when there isn't enough history.
- Advisories: thermal tips (`ThermalAdvisor`) and cell-imbalance warnings
  (`CellAnomalyDetector`, elevated > 50 mV, critical > 100 mV).

### Drive and charge logging
- Trips start and end automatically from the drive pipeline; samples are logged at
  1 Hz while active and downsampled to 0.1 Hz on completion.
- Retention purge on launch: 90 days free, 365 days Pro.
- Per-drive regen analysis (`DriveAnalytics`): gross/net consumption, regen kWh and
  regen share with a rating band.
- Charge sessions logged with energy added, peak/average power and SOC gained.
- Independent coulomb-counted SOH (`BatteryHealthEstimator`), stored separately from
  the BMS figure and only published after a large enough SOC swing.

### Route and charge-stop planning
- Place search, origin/destination swap, ordered stopovers, saved trips and favourite
  places.
- Base route from Apple Maps (no key), OpenRouteService, or Google Directions.
  OpenRouteService is preferred where elevation matters — it returns ascent/descent,
  which is what lets the consumption model do real grade physics.
- Chargers along the corridor from Open Charge Map, Apple Maps, Google Places, or a
  combination; stale-cache and offline states are surfaced rather than shown as fresh
  data.
- `TripSolver`: Dijkstra over (charger, SOC-bucket) nodes with a measured IONIQ 5
  800 V charge curve, pack-temperature derating, a fixed 5 min stop overhead, a
  1.5 min/km detour penalty and an optional price weight.
- Reject a charger and re-solve without spending another routing or charger API call.
- Hand the finished trip to Google Maps (when installed) or Apple Maps — the app
  plans, it does not navigate.

### While driving
- `LiveReplanMonitor` matches the GPS fix onto the routed polyline and compares
  actual against predicted SOC, falling back to dead reckoning without a fix.
  `RouteReplanner` turns drift or an off-route position into re-plan advice.
- Local notifications for charge milestones (80 %, 100 %), low tyre pressure
  (< 220 kPa with hysteresis), re-plan advice, and charger occupancy.
- Occupancy alerts (Pro) warn when every station with *live* availability near the
  next stop is occupied and the stop is minutes away; the notification carries a
  "Re-route" action that commits the parked alternative. Stations with no live status
  are never counted as free.

### CarPlay
Tab bar with Vehicle, Charging, Chargers (point-of-interest map) and Trips. Templates
are mutated in place and refreshes throttled to 2 s — rebuilding flickers and resets
scroll. The scene reads `AppServices.shared`, so phone and car show one adapter
connection's data.

### AI features (Pro, bring your own key)
Gemini (`gemini-flash-lite-latest`) or DeepSeek, selected in Settings, with the user's
own key. A master toggle stops all data leaving the device while keeping the key.
- Post-trip briefing, weekly/monthly digest, charging intelligence, battery health
  report, and a context-aware assistant chat.
- Natural-language trip planning in the Plan tab ("drive to Ipoh, arrive with 30 %").
- Prompts live in `CoreDomain/AiPrompts.swift` — one source, asserted against
  `Fixtures/ai-prompts-golden.txt`, which is shared with the Android repo.

### Backup and restore
- JSON export/import of trips, samples, charge sessions, saved plans, saved places and
  settings. Format version 2 is shared with Android (epoch millis, Android's field
  spelling); format 1 files from either platform still restore.
- Optional background auto-backup (daily/weekly/monthly) via `BGProcessingTask`
  `com.fmz.IoniqTelemetry.autobackup`, written to `Documents/autobackup/` and visible
  in the Files app.

### Pro
One-time non-consumable `ioniq_telemetry_pro` via StoreKit 2. Entitlement is
re-derived from `Transaction.currentEntitlements` at every launch — the UserDefaults
flag is only a launch-time cache so Pro surfaces don't flicker, never the authority.
Pro covers AI features, occupancy alerts, backup/restore and the longer history
window; all live telemetry and battery-safety data is free.

---

## Technical specifications

### OBD stack (`CoreOBD`)
- **Transports:** `BleTransport` (CoreBluetooth), `WifiTransport` (TCP ELM327),
  `ReplayTransport` (recorded sessions, for desk work). The factory in `AppServices`
  picks BLE when the saved address parses as a UUID, WiFi otherwise.
- **Session:** `Elm327Initializer` brings the adapter up; `IsoTpFraming` and
  `IsoTpReassembler` handle multi-frame UDS responses; `PollingScheduler` runs three
  tiers — FAST 1 s, MEDIUM 5 s, SLOW 60 s.
- **Decoding:** vehicle profiles are declarative JSON (`profileId`, usable capacity,
  requests with header/PID/tier, and signals with byte offset, length, formula, unit,
  signedness and range). `DecoderEngine` compiles the `A`/`B`/`C`/`D` byte formulas
  once per signal and discards out-of-range values; `TelemetryAssembler` folds decoded
  signals into a `VehicleTelemetry` frame.
- **Bundled profiles:** `ioniq5_2022_77kwh` (74 kWh usable), `ioniq5_84kwh` (80),
  `ioniq6_77kwh`, `ev6_77kwh`, `gv60_77kwh`.
- **Tools:** `PidSweeper` sweeps UDS service 0x22 across ECU headers to find supported
  PIDs; `ObdSessionRecorder` writes request/response transcripts for replay.

### Drive pipeline (`ConnectedCarService`)
A single consumer of the raw OBD stream corrects each frame (regen vs charging, GPS
speed) before publishing to `TelemetryRepository` — so UI, CarPlay and the trip log
never disagree. `DriveMonitor` and `ParkedStateEvaluator` are not thread-safe by
design and are driven only from here; becoming "driving" is instant, becoming
"parked" needs 10 s without motion evidence, and a nil speed (tunnel) holds state
rather than counting as stopped.

iOS has no foreground service: what keeps the pipeline alive during a drive is the
CoreLocation background session plus the `bluetooth-central` and `location` background
modes. A supervisor ticks every 15 s — 30 s without a decoded frame means the bus is
quiet, 120 s means the session is dead — and reconnects with a 5/10/30/60 s backoff.
A manual disconnect suppresses auto-reconnect until the user connects again.

### Persistence and networking (`CoreData`)
SwiftData entities (`TripEntity`, `SampleEntity`, `ChargeSessionEntity`,
`ChargerEntity`, `SavedTripEntity`, `SavedPlaceEntity`) behind repositories.
Preferences in UserDefaults, API keys in the Keychain (`KeychainStore`). Network calls
go through `NetworkSession` with typed `NetworkError`, retry and a `NetworkMonitor`
reachability check. Chargers are cached and geohashed for area lookups.

### Routing math (`CoreRouting`)
`ConsumptionModel` is a physics model (rolling resistance, aerodynamic drag, grade,
auxiliary load) with multiplicative calibration factors fitted online against logged
trips, clamped to ±30 % and only applied after 200 km of samples. `ChargeCurve` holds
the measured IONIQ 5 DC curve (peak ~235 kW near 20 % SOC, hard taper past 65 %) and
temperature derates from 0.35× below 0 °C to 1.0× between 15–35 °C.

### Permissions and background modes
Bluetooth (adapter), location when-in-use and always (trip logging, corridor
matching), motion (drive detection). Background modes: `bluetooth-central`,
`location`. `UIFileSharingEnabled` for backup files.

### Privacy
No account, no analytics SDK, no ad SDK, no backend of ours. Driving data and API keys
stay on device. Outbound calls are the user's own keys to their chosen providers
(routing, geocoding, chargers, AI) plus the optional build-time Open Charge Map key.
Backups intentionally include API keys so an export is a full restore.

### Configuration

| Key | Where | Notes |
|---|---|---|
| `OPEN_CHARGE_MAP_API_KEY` | `Secrets.xcconfig` → Info.plist | Optional build-time key; OCM 403s unauthenticated requests. A key pasted in Settings overrides it |
| OpenRouteService | Settings | Free, email signup. Routing + geocoding + elevation |
| Google Maps | Settings | Optional: Directions, Places search, charger source, occupancy |
| Gemini / DeepSeek | Settings | Pro AI features, user's own key |

---

## Testing

Swift Testing suites across the packages cover the parked/driving state machine,
charge and tyre monitors, range estimation, polyline math, charger access rules, AI
prompt rendering against the shared golden file, profile parsing and signal byte
offsets, backup v2 round-trips including an Android-written fixture, network retry,
occupancy snapshots, active-plan handling, the route replanner and the occupancy
alert monitor.

## Known limitations

- iPhone only — no iPad layouts, deliberately.
- No turn-by-turn navigation and no CarPlay navigation entitlement; planned trips are
  handed to Apple or Google Maps.
- No voice input on iOS (the Android build's equivalent has no counterpart here),
  though `Speech`/`AVFoundation` are still linked in `project.yml`.
- Route planning needs a routing provider that works for the user's region; Apple Maps
  is keyless but returns no elevation.
- Store screenshots in `store_assets/screenshots/` are simulator placeholders with no
  live data.

## Disclaimer

Not affiliated with, endorsed by, or sponsored by Hyundai, Kia or Genesis.
