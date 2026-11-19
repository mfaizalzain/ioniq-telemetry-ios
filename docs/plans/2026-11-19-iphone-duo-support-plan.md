# iPhone Duo support plan (iOS)

**Date:** 2026-11-19
**Scope:** `~/Desktop/github-repos/ioniq-telemetry-ios` (HEAD `3911ef4`, marketing 1.0.11 / build 21, live on the App Store)
**Request:** "check ioniq telemetry ios app, how we can update to support iphone duo"

**Verdict:** the app installs and runs on iPhone Duo today with no crash and no orientation bug — the
codebase is unusually clean on Apple's two big failure modes (it never reads `UIScreen.main` for
sizing, and never branches on `UIDevice.orientation`). Two real gaps: **(1)** the *release* binary is
still built with the iOS 26 SDK, so on the inner display it runs letterboxed in a centred window;
**(2)** the app has **zero** adaptive layout — no size-class read anywhere — so once it does fill the
inner display it will be one very wide column of cards. (1) is a one-line CI change; (2) is the actual
work, and it is per-screen, not a rewrite.

---

## 1. What iPhone Duo changes (platform facts)

| Fact | Value |
|---|---|
| Inner display | 7.6" 1878×2670 @430ppi → **626×890 pt**, **regular/regular** size classes |
| Outer display | 5.4" 1398×2034 @460ppi → **466×678 pt**, compact width — behaves like today's iPhone |
| Orientation | the inner display **ignores** `UISupportedInterfaceOrientations`; layout must follow size class, not orientation |
| ID | still `UIDeviceFamily = 1` — it is an iPhone app, not an iPad app |
| Poses | opened, closed, partially folded (a **division** reserved region appears down the middle), tent/half-open in landscape; Split View multitasking |
| SDK ladder | iOS 26 SDK build → centred with empty space · iOS 27 SDK → fills the inner display, avoids the side status bar · iOS 27.1+ SDK → edge-to-edge with bars laid out **vertically** under the side status bar |

APIs that matter, all verified present in the installed `iPhoneOS27.2.sdk`
(`SwiftUI.swiftinterface` / `SwiftUICore.swiftinterface` / `UIViewReservedRegion.h`):

- `GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:) -> [ReservedRegion]` — iOS 27.1
- `ReservedRegion.Kind.occlusion` (camera / side status bar) and `.division` (the fold); `QueryOptions.includeInactive` to read the fold band while fully open
- `View.toolbarVerticalBehavior(_:)` with `.automatic` / `.disabled` — iOS 27.1; opt out where a vertical bar looks wrong
- `ConcentricRectangle` / `UICornerConfiguration` — iOS 26, for corner-matched cards on the new shapes

---

## 2. Audit of the current app (verified, not assumed)

Grep results across `IoniqTelemetry/` and `Packages/`:

| Check | Result |
|---|---|
| `UIScreen.main` | **1 hit** — `UI/Trips/TripDetailView.swift:85`, `renderer.scale = UIScreen.main.scale` (share-image renderer). On a two-display device this is the ambiguous-case Apple says will be deprecated. One-line fix: `@Environment(\.displayScale)`. |
| `UIDevice.current.orientation`, `statusBarOrientation`, `interfaceOrientation` | **0 hits** — nothing to unwind |
| `userInterfaceIdiom` / `isPad` / phone checks | **0 hits** |
| `horizontalSizeClass` / `verticalSizeClass` | **0 hits** — the whole app is unadapted |
| Layout | `AppRootView` = bottom `TabView` of 4 tabs; every tab is a single-column `ScrollView` + `LazyVStack`; `MetricTilesGrid` is a hardcoded two-column `LazyVGrid` (`UI/Dashboard/DashboardView.swift:650`) with ~12 tiles |
| Type scale | fixed points, no Dynamic Type: `Packages/CoreUI/Sources/CoreUI/Theme/Typography.swift` (12–32) and the 52 pt SOC readout (`DashboardView.swift:167`) |
| Fixed-width frames | all small chrome (dots, a 180 pt link-preview, a 360 pt share card at `TripDetailView.swift:138`) — no screen-sized assumptions |
| Orientation plist | portrait + both landscapes (`Resources/Info.plist:89-93`) — harmless, the inner display ignores it; leave it |
| Device family | `TARGETED_DEVICE_FAMILY: 1` in `project.yml` — correct for Duo, keep |
| Release SDK (the real bug) | `.github/workflows/ios-release.yml:36` pins `Xcode_26*.app` → archive is built with the **iOS 26 SDK** → letterboxed on Duo |
| Local SDK | this Mac: Xcode 27.2 / SDK 27.2. Verified a simulator build succeeds and the product reports `DTSDKName = iphonesimulator27.2`, `minos 17.0` → resizing already works in Debug |
| Live Activity | `Service/TelemetryLiveActivity.swift` requests an `Activity` but the project ships **no WidgetKit extension**, so there is no custom Duo vertical-Dynamic-Island UI to fix (pre-existing gap, out of scope here) |
| CarPlay | separate scene, unaffected by Duo |

**What that means on the inner display:** 626 pt of width filled by cards designed for 393 pt. The
SOC hero card becomes a metre-wide band, the two-column metric grid becomes two 300 pt columns, the
Trips list rows stretch to full width, and the bottom tab bar is relocated by iOS 27 to the side as a
dock. Nothing breaks; it just wastes the best thing about the device.

---

## 3. Update plan

### P0 — SDK + the one-line fix (tiny, ship first)

1. `ios-release.yml`: stop pinning Xcode 26. Select the newest installed Xcode 27 (`Xcode_27*`, falling back to the newest available with a log line), keeping the existing "no Xcode found" guard. Without this the whole plan is invisible to App Store users.
2. `TripDetailView.swift:85`: `renderer.scale = UIScreen.main.scale` → `@Environment(\.displayScale)`.
3. CI: assert the archive's SDK, e.g. `plutil -p .../Info.plist | grep DTSDKName` must contain `iphoneos27` — so a runner image rollback can't silently re-letterbox us.

### P1 — shared adaptive plumbing in `CoreUI` (one small PR)

4. `AdaptiveLayout` helper: pure functions `columns(for width: CGFloat, minimum: CGFloat)` and a `contentMaxWidth` used by every tab, so layout decisions are testable without a UI test. Unit-test it in `IoniqTelemetryTests` (Duo table: 466 → 2 tiles, 626 → 3, 890 landscape → 4).
5. `AdaptiveMetricsGrid` in `CoreUI` replacing the hardcoded two-column grid: `LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: columns(for: …)))`, driven by `onGeometryChange` (iOS 18+) rather than a `GeometryReader` wrapper, so the fold can resize a live session.
6. Keep the app's 4-tab `TabView`. Do **not** adopt `.sidebarAdaptable` yet — it changes the outer-display UX too, and the outer display is what existing users see. (Optional later: `.tabViewStyle(.sidebarAdaptable)` for a real sidebar when open.)

### P2 — the four screens, in value order

7. **Dashboard**: at regular width, hero card + `MetricTilesGrid` side by side (`HStack`) instead of stacked, tiles 3–4 across, `AIDigestSection` / `BatteryHealthReportView` in a second column. Keep the 2-up phone layout untouched behind the same helper.
8. **Trips**: this is the Mail-shaped screen Apple's HIG points at — `NavigationSplitView` with the trip/charge list as sidebar and `TripDetailView` as detail. Closed it behaves like today (list → push); open it shows both panes, which is also exactly what the fold wants since split views adapt their columns to the fold's symmetry.
9. **Plan**: map/route card and `ItineraryTimeline` + charger sections in two columns when regular; keep the single column when compact.
10. **Settings**: `Form`/grouped rows already adapt; cap content width so rows don't stretch to 626 pt (a readability cap, ~560–640 pt, applied via the shared helper).

### P3 — fold- and pose-specific polish (only after P2 lands)

11. `toolbarVerticalBehavior(.disabled)` on screens whose trailing toolbar item is a single glyph (`ConnectionBadge` on Dashboard, share on TripDetail) if the vertical bar reads wrong in the 27.1 layout.
12. `reservedRegions(kind: .division, options: .includeInactive)` in Plan to keep the full-bleed map and the legs list clear of the crease when partially open. Guard with `if #available(iOS 27.1, *)` — deployment target stays 17.0.
13. Tent mode: landscape is already supported; verify the Dashboard in landscape at 890×626 pt, since a propped-up phone is a plausible in-car pose.
14. Do **not** chase Dynamic Type on this pass: the fixed 12–52 pt scale is deliberate for in-car glanceability. If we revisit it, clamp with `.dynamicTypeSize(...DynamicTypeSize.accessibility1)`.

### P4 — verification

15. SwiftUI previews pinned to Duo geometry: 626×890 with `.environment(\.horizontalSizeClass, .regular)` and `.environment(\.verticalSizeClass, .regular)`, plus the outer 466×678 compact case.
16. Real-hardware pass before the release that claims Duo support.

**Blocker worth stating plainly:** this Mac's Xcode 27.2 has no Duo simulator — `xcrun simctl list devicetypes` has no iPhone Duo (it stops at iPhone 17), `DeviceHub.app` contains no "iPhone Duo" string, and `/Library/Developer/CoreSimulator/Profiles/Runtimes` is empty (simulator runtimes live only as `/Library/Developer/CoreSimulator/Volumes/iOS_23F77` / `iOS_24A5390f`, which is why `simctl` hangs here). Apple's launch material says Duo support in Device Hub is "upcoming". So P2 is developed against previews + the layout unit tests, and confirmed on hardware/Device Hub when Apple ships it. Do not block P0/P1 on that.

---

## 4. Effort and sequencing

| Phase | Size | Risk |
|---|---|---|
| P0 SDK + displayScale + CI assert | ~1 hour, 3 files | low; App Store submission is the only side effect |
| P1 adaptive helper + grid + tests | half a day | low; helper is opt-in per call site |
| P2 Dashboard + Trips split view | 1–1.5 days | medium; `NavigationSplitView` on Trips touches selection state and the delete-alert plumbing |
| P2 Plan + Settings caps | half a day | low |
| P3 fold/toolbar polish | half a day | low, all `#available`-guarded |

Each phase is independently shippable and independently verifiable on the phone, matching the
push-incrementally workflow. Nothing here needs a new entitlement, a new Info.plist key, an App Store
metadata change, or a deployment-target bump.

## 5. Explicitly out of scope

- iPad (`TARGETED_DEVICE_FAMILY` stays `1`) — Duo does not change that decision and the 2.4.1 risk argument in `project.yml` still holds.
- The missing WidgetKit extension for Live Activities (pre-existing, unrelated to Duo).
- CarPlay layout (separate scene, no fold semantics).
