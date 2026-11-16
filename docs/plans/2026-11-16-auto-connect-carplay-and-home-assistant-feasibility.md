# Feasibility study (iOS) — unattended auto-connect, CarPlay control, Home Assistant export

**Date:** 2026-11-16
**Scope:** `~/Desktop/github-repos/ioniq-telemetry-ios` (HEAD `ea07b0b`, 1.0.11, live on the App Store)
**Mirror of:** `docs/plans/2026-11-16-auto-connect-and-home-assistant-feasibility.md` (Android, same request)

Roberto's three asks, evaluated against the iOS app:

1. Connect to the dongle automatically, without opening the app.
2. At minimum, a way to connect from the car dashboard (CarPlay here, Android Auto there).
3. A way to get the data into Home Assistant.

**Verdict:** (2) is nearly free — the CarPlay scene already boots the whole stack and switches the
OBD session on, so the missing piece is only an explicit button and an honest state row. (1) is
partly built: `autoConnectLastAdapter()` already runs at launch and an armed `standingReconnect`
already re-links in the background; what is missing is being *woken* when the app is not running, which
Core Bluetooth does well **if** state restoration is opted into. (3) is the same shape as Android, and
iOS is actually the better place for it because credentials already land in the Keychain.

One hard platform fact to state up front: **iOS cannot talk to a classic ELM327 (SPP) dongle at all.**
There is no RFCOMM API; `ExternalAccessory` is MFi-only. The app is BLE-only (`BleTransport`,
`BleScanner`) plus Wi-Fi (`WifiTransport`), which is correct — but it means "auto-connect" on iOS is
strictly a BLE story, and a user with a cheap SPP clone is on the wrong hardware.

---

## What already exists (verified)

| Asset | Where | Relevance |
|---|---|---|
| Auto-connect at launch | `App/AppServices.swift:140` → `autoConnectLastAdapter()` (`:220`) | Half of ask #1 is already shipped. |
| Armed background reconnect | `CoreOBD/Transport/BleTransport.swift:193 beginStandingReconnect()`, re-armed on drop (`:217`, `:446`) | A standing `centralManager.connect` is exactly the primitive iOS needs; it survives suspension. |
| Suppression semantics | `autoReconnectSuppressed` (`AppServices`), `cancelStandingReconnect()` | "I tapped Disconnect" is respected — important once auto-connect gets more aggressive. |
| Background modes | `Info.plist`: `UIBackgroundModes = [bluetooth-central, location]` | Both already declared. No entitlement work needed. |
| Background location | `Service/VehicleLocationProvider.swift:86-118` — `requestAlwaysAuthorization`, `allowsBackgroundLocationUpdates`, `showsBackgroundLocationIndicator` | Trips can log GPS while backgrounded; this is what keeps the session alive during a drive. |
| Supervisor + backoff | `Service/ConnectedCarService.swift:78` — backoff `[5,10,30,60]`, `framesQuiet`/`sessionDead`/`tripIdleEnd` | Same design as Android's FGS loop; no change needed for auto-start. |
| CarPlay scene | `CarPlay/CarPlaySceneDelegate.swift` — calls `AppServices.shared.initialize()` on connect | **CarPlay launch already triggers auto-connect.** |
| CarPlay status surface | `CarPlay/CarPlayCoordinator.swift:32` `CPInformationTemplate(title:"Vehicle", actions: [])`, `connectionState` cached at `:53`, "Adapter" row at `:229` | A Connect/Disconnect button has a home and a live state to read. |
| BGTaskScheduler | `AppServices.swift:276-312`, `BGTaskSchedulerPermittedIdentifiers` in Info.plist | Pattern + plumbing for deferred work already exist (used for auto-backup). |
| Backup / export | `CoreData/Repositories/BackupRepository.swift` (format v2, tested) | Payload serialiser for HA is already there. |
| Secret storage | `CoreData/Repositories/KeychainStore.swift` | MQTT/webhook credentials can be stored properly here — better than Android, which keeps API keys in plain DataStore. |

Gaps: **no** `CBCentralManagerOptionRestoreIdentifierKey`, **no** `centralManager(_:willRestoreState:)`,
no launch-time central manager (the `CBCentralManager` is constructed inside `BleTransport.init`, i.e.
only once a connect is attempted — too late for restoration), no `CPTextButton` actions on the CarPlay
templates, and no network export path.

---

## 1. Auto-connect without opening the app

### The iOS mechanism is different from Android's, and simpler

Android needs a wake-up exemption (CDM presence, notification, boot) because a foreground service may
not be started from the background. iOS instead lets a **pending `connect()` survive suspension**: with
`bluetooth-central` declared, Core Bluetooth holds the request on your behalf, and when the dongle
powers up (car on) the app is woken, `centralManager(_:didConnect:)` fires, and the session continues.
That is precisely `beginStandingReconnect()`, which already exists.

Two things are missing to make it "unattended":

**a) Opt into state restoration.** Per Apple's docs, a central manager created with
`CBCentralManagerOptionRestoreIdentifierKey` gets `centralManager(_:willRestoreState:)` called when the
system relaunches the app **in the background** to service an active or pending connection. Two
non-obvious requirements, both of which collide with the current code shape:

- the identifier must be **stable across launches** (persist it, e.g. in `UserDefaults`), and
- the manager must be created **before** iOS calls `willRestoreState` — i.e. at app init, not when the
  user taps Connect. The current `BleTransport` creates it lazily, so the app needs a small
  launch-time owner (`BlePresenceHost`) that constructs the manager with the restore identifier,
  receives `willRestoreState`, hands restored `CBPeripheral`s to the transport, and re-arms the
  standing connect.
- Also relevant in scene-based apps: `launchOptions` is always nil, so the UID cannot be read back
  from launch options — it must be persisted.

**b) Re-arm on every launch and after each drop.** `AppServices.initialize()` already calls
`autoConnectLastAdapter()`; when that fails because the car is asleep, it should fall back to
`beginStandingReconnect()` instead of leaving the app disconnected until the next launch. Today the
supervisor retries during an active session, but nothing re-arms the standing request after the app is
cold-started while parked.

### Honest limits — where iOS will still miss a trip

- **User force-quit** (`swipe up` in the app switcher) is absolute: iOS will not relaunch a force-quit
  app, ever. No API works around it. Same class of limit as Android's OEM battery killers, but
  *user-caused* and therefore explainable in the settings copy.
- **System termination under memory pressure** is recoverable *only* via state restoration (point a).
- **A dongle that is already connected to something else** (e.g. left paired to the phone app of a
  different tool) will not accept the link.
- **ELM handshake latency** means a drive that starts and ends in under ~30 s may never produce a
  decoded frame; not fixable.
- Background BLE scanning is **service-UUID filtered and slower**, so if the peripheral identifier ever
  changes (adapter swapped, firmware reset) the standing connect fails silently. The UI should surface
  "adapter last seen <date>" so a stale identifier is visible rather than mysterious.

Realistic expectation: high capture rate (iOS has no third-party battery killers), degrading to zero
only after a force-quit.

### Implementation sketch

- `CoreOBD`: new `BlePresenceHost` (or extend `BleScanner`) that owns the launch-time
  `CBCentralManager` with a persisted restore identifier; implement `willRestoreState`; expose
  `restoredPeripheral` to `BleTransport`.
- `BleTransport`: accept an injected central manager instead of constructing one; keep
  `beginStandingReconnect()` as the re-arm path.
- `AppServices.initialize()`: `autoConnectLastAdapter()` → on failure `obdManager.beginStandingReconnect()`.
- `PreferencesRepository`: `autoConnectEnabled: Bool` (default on for existing users is debatable —
  recommend explicit opt-in row in Settings with a one-line explanation, plus "adapter last seen").
- `Info.plist`: nothing new (both background modes already present).
- Settings copy must say: "Auto-connect is suspended if you force-quit the app."

**Effort:** 2–3 dev-days, most of it in the Core Bluetooth plumbing and cold-start testing.
**Testing:** real device + real adapter; simulator cannot reproduce restoration. Test matrix: cold start
→ drive; force-quit → drive (must stay disconnected, no crash); low-memory termination → drive (must
recover).

---

## 2. Connect from the car dashboard (CarPlay)

Cheaper than Android, and partly already true:

- `CarPlaySceneDelegate.templateApplicationScene(_:didConnect:)` already awaits
  `AppServices.shared.initialize()`, which calls `autoConnectLastAdapter()`. **So starting CarPlay
  already starts the session** — Roberto may not realise this is why his CarPlay trips do log.
- What is missing is user-facing control and honesty about state: `CPInformationTemplate` for status is
  constructed with `actions: []`, while `connectionState` is already tracked and rendered as an
  "Adapter" row.

Change: build two `CPTextButton`s (`Connect` / `Disconnect`, template accepts up to two actions) whose
handlers call `services.connect(to: savedDevice)` / `services.disconnect(userInitiated: true)`, and
refresh the template on `connectionState` change. Driving-task rules are satisfied — these are
secondary actions, not text entry. If no adapter is saved, show "Pair in the phone app first" as the
button's disabled state rather than a tapped no-op.

**Caveat that decides timing:** the CarPlay entitlement is `com.apple.developer.carplay-charging`
(`Resources/IoniqTelemetry-CarPlay.entitlements`) and the entitlement file's own comment states Apple
must grant it. Simulator builds work without approval; **a device build only signs once Apple has
granted it**. So this work is finished-and-waiting on an Apple approval, not on code.

**Effort:** ~0.5 day + CarPlay Simulator verification.

---

## 3. Home Assistant export

Identical decision to Android, and the same recommendation:

### A. MQTT with discovery — recommended
CocoaMQTT (or MQTTNIO). Publish retained discovery configs so HA creates the device and entities with
the right `device_class`/`state_class` (Energy dashboard needs `total_increasing` kWh). Live snapshot
while a session runs, plus one aggregate at trip end. Publish from the app while it is running; on iOS
there is **no** long-lived background socket — a suspended app cannot hold MQTT open, so per-trip and
on-foreground publishing is the honest scope. Use `BGProcessingTask` (already registered for
auto-backup) for a deferred flush of anything queued while offline.

### B. HA webhook — smallest v1
`POST {ha}/api/webhook/{id}`, JSON body, no auth header. `URLSession` via the existing
`NetworkSession`/`NetworkMonitor` and the retry helper already in `CoreData`. Reuses the
`BackupRepository` payload shape. ~1 day, and the user writes their own automation + template sensors.

### C. HA REST API with a long-lived token — not recommended
Orphan entities, no device metadata, and a full admin token sitting on the phone (even in the Keychain,
it is more authority than the feature needs).

Security: credentials in `KeychainStore` (already exists), HTTPS only, and offer the Nabu Casa URL as
the documented default path so nobody port-forwards plain HTTP.

**Effort:** B ≈ 1 day, A ≈ 2–3 days, plus docs. Parity with Android is worth having: the same MQTT
topic/discovery layout should serve both apps so one HA automation works for either phone.

---

## Cross-platform notes worth telling the user

- **Dongle compatibility differs by platform.** Android supports BLE and classic SPP; iOS supports BLE
  (and Wi-Fi) only. If he ever considers iOS, the adapter must be BLE.
- **CarPlay needs Apple's `carplay-charging` entitlement**; Android Auto has no equivalent gate beyond
  Play review. This is the one place where the Android feature can ship first, unmoved by third-party
  approval.
- **The Android design transfers**: "remembered adapter + presence-triggered wake + backoff + give up
  after 5 min" is the same architecture; only the wake primitive differs (CDM/presence vs. Core
  Bluetooth restoration).
- **Force-quit is the iOS version of Android's OEM battery killer.** Both need the same words in the UI:
  *this can't work while the app is force-stopped.*

## Recommended sequence (iOS)

1. CarPlay Connect/Disconnect buttons (#2) — small, and immediately reduces "open the phone app" for
   CarPlay drivers. Can be built now; ships when Apple grants the entitlement.
2. Core Bluetooth state restoration + standing-connect re-arm at launch (#1).
3. HA export — webhook first if speed matters, MQTT discovery for the proper version (shared topic
   schema with Android).

Total: roughly 4–5 dev-days, excluding Apple CarPlay approval wait.
