# App Store Listing — IONIQ Telemetry (iOS)

Written against what the iOS build actually ships. It is **not** a copy of the Play
listing: there are no ads, no voice input, and CarPlay stands in for Android Auto.
Claiming any of those would be a rejection under App Store Review 2.3 (accurate
metadata).

Version at time of writing: **1.0.0 (1)** · Bundle ID `com.fmz.IoniqTelemetry`

---

## Metadata

### App Name (max 30)
`IONIQ Telemetry`

### Subtitle (max 30)
`Live 800V EV battery data`

### Promotional Text (max 170, editable without review)
```text
Read your E-GMP EV's real 800V battery over a Bluetooth OBD-II adapter, log every drive, and plan charging stops around the battery you actually have.
```

### Description (max 4000)
```text
IONIQ Telemetry turns a Bluetooth OBD-II adapter into a live window on your electric car's 800V battery — for Hyundai IONIQ 5 and 6, Kia EV6 and EV9, Genesis GV60, and other E-GMP vehicles.

GROUNDED IN YOUR REAL BATTERY, NOT ESTIMATES
Generic route planners guess at your range from a model year. IONIQ Telemetry reads the pack itself: true BMS state of charge, coulomb-counted state of health, cell voltage delta in millivolts, and per-module temperatures. Route elevation is factored in, so a climb is planned as a climb.

KEY FEATURES

• 800V PACK AND CELL HEALTH
True BMS state of charge, independently measured state of health from charge-session energy integration, cell delta in mV, and per-module temperatures to catch degradation early.

• 12V AUXILIARY BATTERY GUARD
Rest voltage, LDC charging status and a health read, so the classic E-GMP 12V drain doesn't strand you.

• DC FAST CHARGING MONITOR
Live charging power from AC Level 2 up to 350 kW DC, with pack temperature, so you can see what preconditioning is buying you. Every session is logged with energy added, peak and average power, and the SOC gained.

• AUTOMATIC TRIP LOGGING
Drives are recorded whenever the adapter is connected — distance, energy, efficiency and the full SOC, speed and power traces, plus a regen analysis showing how much braking energy came back.

• BATTERY-AWARE ROUTE PLANNING
Enter a route, add stopovers, and an on-device solver picks charging stops from real charger data around your current state of charge and target arrival buffer. Hand the whole trip to Google Maps with one tap.

• CARPLAY
A glanceable grid on the car's screen — state of charge, range, power flow and battery health — with drill-downs to battery detail and trip history.

• AI ASSISTANT (PRO, BRING YOUR OWN KEY)
Describe a trip in plain language — "drive to Penang, stop in Ipoh, arrive with 30%" — and it becomes a full charging plan. Powered by your own Google Gemini API key.

• PRIVACY-FIRST AND ON-DEVICE
Your driving data and your API keys stay on your device. No account, no tracking, nothing sold.

WHAT YOU NEED
A standard Bluetooth OBD-II adapter (Vgate iCar Pro, OBDLink CX, VEEPEAK and ELM327-compatible dongles).

Route planning needs your own free OpenRouteService API key — email signup, no credit card. It is free for everyone, not a Pro feature, and requests count against your own quota rather than a shared one.

Pro is a one-time purchase, not a subscription. It unlocks the AI assistant, charger occupancy alerts, backup and restore, and extends trip history from 90 days to a year. All live telemetry and battery safety data is in the free tier.

COMPATIBLE VEHICLES
Hyundai IONIQ 5 (2021+), IONIQ 6, Kia EV6, EV9, Genesis GV60, and other E-GMP platform EVs.

IONIQ Telemetry is not affiliated with, endorsed by, or sponsored by Hyundai, Kia or Genesis.
```

### Keywords (max 100 chars, comma separated, no spaces)
```text
EV,OBD2,IONIQ,EV6,electric,battery,SOH,charging,telemetry,ELM327,EGMP,range,trip,SOC
```
82 characters. Do not repeat words already in the name or subtitle — Apple indexes
those separately, so "IONIQ" and "telemetry" here are arguably wasted; drop them if
you want room for more.

### What's New (first release)
```text
First release.

• Live 800V pack data over a Bluetooth OBD-II adapter
• True BMS state of charge and coulomb-counted state of health
• DC fast-charge monitor with session history
• 12V auxiliary battery guard
• Automatic trip logging with regen analysis
• Battery-aware route planning with charging stops
• CarPlay
```

### URLs
- **Support URL** (required): `https://ioniq.faizalmzain.com`
- **Marketing URL** (optional): `https://ioniq.faizalmzain.com`
- **Privacy Policy URL** (required): `https://ioniq.faizalmzain.com/privacy`

### Category
Primary **Navigation**, secondary **Utilities**. (Play uses Auto & Vehicles; the App
Store has no equivalent, and Navigation matches the planning feature reviewers will
actually exercise.)

### Age Rating
4+ — no objectionable content. Answer "No" to every content question.

---

## In-App Purchase

| Field | Value |
|---|---|
| Reference Name | Ioniq Telemetry Pro |
| Product ID | `ioniq_telemetry_pro` |
| Type | Non-Consumable |
| Price | USD 4.99 |
| Display Name | IONIQ Telemetry Pro |
| Description | One-time purchase. AI assistant, charger occupancy alerts, backup and restore, and a full year of trip history. |

There is no subscription. Do not add renewal or cancellation copy anywhere in the
listing or the app — it would contradict the product type and fail review.

---

## Screenshots

Required: **6.9-inch iPhone**, 1320 × 2868. Captured from an iPhone 17 Pro Max
simulator, in `store_assets/screenshots/`:

| File | Screen |
|---|---|
| `iphone_69_dashboard.png` | Dashboard |
| `iphone_69_trips.png` | Trips |
| `iphone_69_plan.png` | Route planner |
| `iphone_69_settings.png` | Settings |

> **These are placeholders and should not be uploaded as-is.** They were captured on
> a simulator with no OBD adapter, no API keys and no trip history, so the gauges
> read "—", the trip list is an empty state, and the planner has no route. They prove
> the layout, nothing more. Recapture after a real drive with the dongle connected so
> the screenshots show live SOC, a logged trip with its charts, and a solved plan with
> charging stops.

**No iPad screenshots needed.** The app is iPhone-only:
`TARGETED_DEVICE_FAMILY = 1` on every configuration, and the iPad orientation key
is gone from Info.plist. App Store Connect will not ask for iPad captures, and
there is no stretched-iPhone iPad build to fail Review 2.4.1.

Not required by the store, but worth having if you promote CarPlay: a real capture
of the CarPlay template from the simulator's External Displays → CarPlay.

---

## App Privacy answers (App Store Connect → App Privacy)

The app has no analytics SDK, no ad SDK, no account system, and no backend of its
own. Everything below is what the code actually does.

**Data collected: none.** Answer "No" to "Do you or your third-party partners
collect data from this app?" — nothing is transmitted to *you*.

Be ready to explain these in review notes, since the app does make network calls:

| Call | Destination | Sent | Why it isn't "collection" |
|---|---|---|---|
| Route planning | OpenRouteService or Google Directions | Route coordinates | User's own API key, user-initiated, not retained by us |
| Place search | OpenRouteService Pelias or Google Places | Search text, optional map centre | Same |
| Charger lookup | Open Charge Map or Google Places | Bounding box or circle centre | Same; OCM key ships with the app |
| AI planning (Pro) | Google Gemini | The trip sentence and plan context | User's own Gemini key, opt-in |

Location: used for trip logging and route corridor matching, stays on device.
Declared as `NSLocationWhenInUseUsageDescription` / `Always` for background drive
logging. Bluetooth: OBD adapter only.

**Backups include API keys by design** — an export is a full restore of the user's
setup. If asked, that is a deliberate product decision, and the file never leaves the
device unless the user shares it.

---

## Pre-submission checklist

- [ ] `Secrets.xcconfig` present on the build machine — it is gitignored, and without
      it `OPEN_CHARGE_MAP_API_KEY` resolves empty and charger lookup 403s
- [ ] `https://ioniq.faizalmzain.com/privacy` is live and reachable
- [ ] `ioniq_telemetry_pro` created, priced, and in "Ready to Submit"
- [ ] Screenshots recaptured with real data (see above)
- [x] iPhone-only — no iPad build, no iPad screenshots
- [ ] Review notes explain that full functionality needs an OBD-II dongle and a free
      OpenRouteService key, and give the reviewer a key to test with — otherwise the
      Plan tab looks broken and Review 2.1 rejections follow
- [ ] Demo account: not applicable, no login
- [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` bumped for each upload
