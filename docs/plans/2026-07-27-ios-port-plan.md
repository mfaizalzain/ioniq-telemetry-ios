# Ioniq Telemetry → iOS Port Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Port the Ioniq Telemetry Android app to iOS with identical branding, CarPlay support, and modern iOS design principles.

**Architecture:** Native SwiftUI app with modular Swift packages mirroring Android's clean architecture (Domain → Data → UI). CoreBluetooth replaces Android Bluetooth SPP/BLE. CarPlay via CarPlay framework templates. Same app icon adapted from Android adaptive icon vectors.

**Tech Stack:** Swift 6, SwiftUI, CoreBluetooth, CarPlay, SwiftData, StoreKit 2, MapKit, XcodeGen, iOS 17.0+ deployment target.

---

## Project Structure

```
ioniq-telemetry-ios/
├── project.yml                 # XcodeGen project definition
├── IoniqTelemetry/             # Main app target
│   ├── App/
│   │   ├── IoniqTelemetryApp.swift
│   │   ├── AppRootView.swift
│   │   └── AppServices.swift
│   ├── UI/
│   │   ├── Dashboard/
│   │   ├── Trips/
│   │   ├── Plan/
│   │   ├── Settings/
│   │   ├── Paywall/
│   │   └── Components/
│   ├── Service/                # Background monitors
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   └── Info.plist
│   └── CarPlay/
│       ├── CarPlaySceneDelegate.swift
│       └── Templates/
├── Packages/
│   ├── CoreOBD/                # OBD-II communication
│   ├── CoreDomain/             # Models & protocols
│   ├── CoreData/               # Repositories & persistence
│   ├── CoreRouting/            # Route calculation
│   └── CoreUI/                 # Shared UI components
└── IoniqTelemetryTests/
```

---

## Phase 1: Project Scaffolding & Icon

### Task 1: Create XcodeGen project.yml

**Objective:** Set up the iOS project with XcodeGen for declarative project management.

**Files:**
- Create: `ioniq-telemetry-ios/project.yml`

**Step 1: Write project.yml**

```yaml
name: IoniqTelemetry
options:
  bundleIdPrefix: com.fmz
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "16.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    DEVELOPMENT_TEAM: "S232V5F699"
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: "1"
targets:
  IoniqTelemetry:
    type: application
    platform: iOS
    sources:
      - IoniqTelemetry
    settings:
      base:
        INFOPLIST_FILE: IoniqTelemetry/Resources/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: com.fmz.ioniqtelemetry
        ENABLE_PREVIEWS: YES
    dependencies:
      - sdk: CoreBluetooth.framework
      - sdk: CarPlay.framework
      - sdk: MapKit.framework
      - sdk: SwiftUI.framework
      - sdk: SwiftData.framework
      - sdk: StoreKit.framework
      - sdk: BackgroundTasks.framework
      - package: CoreOBD
      - package: CoreDomain
      - package: CoreData
      - package: CoreRouting
      - package: CoreUI
  IoniqTelemetryTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - IoniqTelemetryTests
    dependencies:
      - target: IoniqTelemetry
packages:
  CoreOBD:
    path: Packages/CoreOBD
  CoreDomain:
    path: Packages/CoreDomain
  CoreData:
    path: Packages/CoreData
  CoreRouting:
    path: Packages/CoreRouting
  CoreUI:
    path: Packages/CoreUI
schemes:
  IoniqTelemetry:
    build:
      targets:
        IoniqTelemetry: all
    run:
      config: Debug
    archive:
      config: Release
```

**Step 2: Generate Xcode project**

Run: `cd ioniq-telemetry-ios && xcodegen generate`
Expected: `IoniqTelemetry.xcodeproj` created

**Step 3: Commit**

```bash
git add project.yml
git commit -m "chore: XcodeGen project scaffolding"
```

---

### Task 2: Create App Icon from Android Source

**Objective:** Convert the Android adaptive icon (vector drawables) to iOS AppIcon set.

**Source files (Android):**
- `app/src/main/res/drawable/ic_launcher_foreground.xml` — SOC gauge ring + lightning bolt
- `app/src/main/res/drawable/ic_launcher_background.xml` — dark navy gradient with speed lines

**Files:**
- Create: `IoniqTelemetry/Resources/Assets.xcassets/AppIcon.appiconset/`
- Create: `IoniqTelemetry/Resources/Assets.xcassets/BrandLogo.imageset/`

**Step 1: Create Python icon generator**

Create `scripts/generate_icons.py`:

```python
#!/usr/bin/env python3
"""Generate iOS AppIcon from Android vector drawables."""
from PIL import Image, ImageDraw
import math
import os

SIZES = [
    (20, 2), (20, 3), (29, 2), (29, 3), (40, 2), (40, 3),
    (60, 2), (60, 3), (76, 1), (76, 2), (83.5, 2), (1024, 1)
]

def draw_icon(size: int) -> Image.Image:
    """Render the Ioniq Telemetry icon at given pixel size."""
    scale = size / 108.0
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Background: dark navy gradient
    for y in range(size):
        t = y / size
        r = int(0x13 + (0x06 - 0x13) * t)
        g = int(0x20 + (0x0B - 0x20) * t)
        b = int(0x3A + (0x15 - 0x3A) * t)
        draw.line([(0, y), (size, y)], fill=(r, g, b, 255))

    # Diagonal speed lines
    draw.line([(-10*scale, 84*scale), (60*scale, 14*scale)],
              fill=(0x17, 0xE8, 0xC2, 13), width=int(10*scale))
    draw.line([(20*scale, 110*scale), (104*scale, 26*scale)],
              fill=(0x17, 0xE8, 0xC2, 10), width=int(14*scale))

    # SOC gauge track (dim arc)
    cx, cy = 54 * scale, 54 * scale
    radius = 24.6 * scale
    bbox = [cx - radius, cy - radius, cx + radius, cy + radius]
    draw.arc(bbox, start=160, end=160+220, fill=(0x2E, 0x3F, 0x5F, 255), width=int(6.5*scale))

    # SOC gauge ring (teal gradient, 78% trim)
    sweep = 220 * 0.78
    # Draw as segmented arc for gradient effect
    steps = 50
    for i in range(steps):
        t0 = i / steps
        t1 = (i + 1) / steps
        a0 = math.radians(160 + sweep * t0)
        a1 = math.radians(160 + sweep * t1)
        # Teal gradient: #0FBFA0 → #3CF5D8
        r = int(0x0F + (0x3C - 0x0F) * t0)
        g = int(0xBF + (0xF5 - 0xBF) * t0)
        b = int(0xA0 + (0xD8 - 0xA0) * t0)
        x0 = cx + radius * math.cos(a0)
        y0 = cy + radius * math.sin(a0)
        x1 = cx + radius * math.cos(a1)
        y1 = cy + radius * math.sin(a1)
        draw.line([(x0, y0), (x1, y1)], fill=(r, g, b, 255), width=int(6.5*scale))

    # Lightning bolt
    bolt = [
        (57.5*scale, 36.5*scale), (43*scale, 57.5*scale),
        (51.5*scale, 57.5*scale), (48.5*scale, 71.5*scale),
        (64.5*scale, 50*scale), (55.5*scale, 50*scale)
    ]
    draw.polygon(bolt, fill=(255, 255, 255, 255))
    # Subtle teal overlay
    draw.polygon(bolt, fill=(0x17, 0xE8, 0xC2, 0x33))

    return img

def main():
    base = "IoniqTelemetry/Resources/Assets.xcassets/AppIcon.appiconset"
    os.makedirs(base, exist_ok=True)

    contents = {"images": [], "info": {"version": 1, "author": "xcode"}}

    for points, scale in SIZES:
        pixels = int(points * scale)
        img = draw_icon(pixels)
        name = f"icon-{points}@{scale}x.png"
        img.save(f"{base}/{name}")

        idiom = "iphone" if points in (20, 29, 40, 60) else ("ipad" if points in (76, 83.5) else "ios-marketing")
        contents["images"].append({
            "size": f"{points}x{points}",
            "idiom": idiom,
            "filename": name,
            "scale": f"{scale}x"
        })

    import json
    with open(f"{base}/Contents.json", "w") as f:
        json.dump(contents, f, indent=2)

    print(f"Generated {len(SIZES)} icon sizes")

if __name__ == "__main__":
    main()
```

**Step 2: Generate icons**

Run: `python3 scripts/generate_icons.py`
Expected: All icon PNGs + Contents.json in AppIcon.appiconset

**Step 3: Create BrandLogo image set**

```bash
mkdir -p IoniqTelemetry/Resources/Assets.xcassets/BrandLogo.imageset
cp IoniqTelemetry/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024@1x.png \
   IoniqTelemetry/Resources/Assets.xcassets/BrandLogo.imageset/brand-logo.png
```

Create `BrandLogo.imageset/Contents.json`:
```json
{
  "images": [
    {"idiom": "universal", "filename": "brand-logo.png", "scale": "1x"}
  ],
  "info": {"version": 1, "author": "xcode"}
}
```

**Step 4: Commit**

```bash
git add scripts/generate_icons.py IoniqTelemetry/Resources/Assets.xcassets/
git commit -m "feat: app icon and brand logo from Android adaptive icon"
```

---

## Phase 2: Core Packages (Domain & Data)

### Task 3: CoreDomain Package — Models

**Objective:** Port all domain models from Kotlin to Swift.

**Files:**
- Create: `Packages/CoreDomain/Sources/CoreDomain/Models/VehicleTelemetry.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Models/Charger.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Models/TripPlan.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Models/TripRequest.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Models/ObdDevice.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Models/ParkedState.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Models/CopilotContext.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Models/CellAnomalyDetector.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Models/ThermalAdvisor.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Models/Constants.swift`

**Step 1: VehicleTelemetry.swift**

```swift
import Foundation

public struct VehicleTelemetry: Sendable, Equatable {
    public var timestamp: Date
    public var speedKph: Float?
    public var socPercent: Float?
    public var sohPercent: Float?
    public var packVoltage: Float?
    public var packCurrent: Float?
    public var powerKw: Float?
    public var cellDeltaMv: Float?
    public var maxCellTempC: Float?
    public var minCellTempC: Float?
    public var avgCellTempC: Float?
    public var auxBatteryVoltage: Float?
    public var odometerKm: Float?
    public var cabinTempC: Float?
    public var setTempC: Float?
    public var tirePressures: [Float?]  // FL, FR, RL, RR in kPa
    public var tireTemps: [Float?]      // FL, FR, RL, RR in °C
    public var isCharging: Bool
    public var chargeMethod: String?
    public var chargePowerKw: Float?
    public var latitude: Double?
    public var longitude: Double?

    public init(
        timestamp: Date = Date(),
        speedKph: Float? = nil,
        socPercent: Float? = nil,
        sohPercent: Float? = nil,
        packVoltage: Float? = nil,
        packCurrent: Float? = nil,
        powerKw: Float? = nil,
        cellDeltaMv: Float? = nil,
        maxCellTempC: Float? = nil,
        minCellTempC: Float? = nil,
        avgCellTempC: Float? = nil,
        auxBatteryVoltage: Float? = nil,
        odometerKm: Float? = nil,
        cabinTempC: Float? = nil,
        setTempC: Float? = nil,
        tirePressures: [Float?] = [nil, nil, nil, nil],
        tireTemps: [Float?] = [nil, nil, nil, nil],
        isCharging: Bool = false,
        chargeMethod: String? = nil,
        chargePowerKw: Float? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.timestamp = timestamp
        self.speedKph = speedKph
        self.socPercent = socPercent
        self.sohPercent = sohPercent
        self.packVoltage = packVoltage
        self.packCurrent = packCurrent
        self.powerKw = powerKw
        self.cellDeltaMv = cellDeltaMv
        self.maxCellTempC = maxCellTempC
        self.minCellTempC = minCellTempC
        self.avgCellTempC = avgCellTempC
        self.auxBatteryVoltage = auxBatteryVoltage
        self.odometerKm = odometerKm
        self.cabinTempC = cabinTempC
        self.setTempC = setTempC
        self.tirePressures = tirePressures
        self.tireTemps = tireTemps
        self.isCharging = isCharging
        self.chargeMethod = chargeMethod
        self.chargePowerKw = chargePowerKw
        self.latitude = latitude
        self.longitude = longitude
    }
}
```

**Step 2: Charger.swift**

```swift
import Foundation

public struct Charger: Sendable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var powerKw: Float?
    public var usageCost: String?
    public var pricePerKwh: Float?
    public var network: String?
    public var connectors: [String]?
    public var isAvailable: Bool?

    public init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        powerKw: Float? = nil,
        usageCost: String? = nil,
        pricePerKwh: Float? = nil,
        network: String? = nil,
        connectors: [String]? = nil,
        isAvailable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.powerKw = powerKw
        self.usageCost = usageCost
        self.pricePerKwh = pricePerKwh
        self.network = network
        self.connectors = connectors
        self.isAvailable = isAvailable
    }
}
```

**Step 3: TripPlan.swift**

```swift
import Foundation

public struct TripPlan: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var origin: String
    public var destination: String
    public var originLat: Double?
    public var originLon: Double?
    public var destLat: Double?
    public var destLon: Double?
    public var totalDistanceKm: Float
    public var totalDurationMinutes: Int
    public var departureSocPercent: Float
    public var arrivalSocPercent: Float
    public var reservePercent: Float
    public var stops: [ChargingStop]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        origin: String,
        destination: String,
        originLat: Double? = nil,
        originLon: Double? = nil,
        destLat: Double? = nil,
        destLon: Double? = nil,
        totalDistanceKm: Float,
        totalDurationMinutes: Int,
        departureSocPercent: Float,
        arrivalSocPercent: Float,
        reservePercent: Float = 20.0,
        stops: [ChargingStop] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.origin = origin
        self.destination = destination
        self.originLat = originLat
        self.originLon = originLon
        self.destLat = destLat
        self.destLon = destLon
        self.totalDistanceKm = totalDistanceKm
        self.totalDurationMinutes = totalDurationMinutes
        self.departureSocPercent = departureSocPercent
        self.arrivalSocPercent = arrivalSocPercent
        self.reservePercent = reservePercent
        self.stops = stops
        self.createdAt = createdAt
    }
}

public struct ChargingStop: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var charger: Charger
    public var arrivalSocPercent: Float
    public var departureSocPercent: Float
    public var chargeDurationMinutes: Int
    public var distanceFromStartKm: Float

    public init(
        id: UUID = UUID(),
        charger: Charger,
        arrivalSocPercent: Float,
        departureSocPercent: Float,
        chargeDurationMinutes: Int,
        distanceFromStartKm: Float
    ) {
        self.id = id
        self.charger = charger
        self.arrivalSocPercent = arrivalSocPercent
        self.departureSocPercent = departureSocPercent
        self.chargeDurationMinutes = chargeDurationMinutes
        self.distanceFromStartKm = distanceFromStartKm
    }
}
```

**Step 4: Remaining models (ObdDevice, TripRequest, ParkedState, CopilotContext, CellAnomalyDetector, ThermalAdvisor, Constants)**

Port each from `core-domain/src/main/kotlin/com/fmz/ioniqtelemetry/domain/model/`. See Android source for exact fields.

**Step 5: Create Package.swift for CoreDomain**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreDomain",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreDomain", targets: ["CoreDomain"])
    ],
    targets: [
        .target(name: "CoreDomain"),
        .testTarget(name: "CoreDomainTests", dependencies: ["CoreDomain"])
    ]
)
```

**Step 6: Commit**

```bash
git add Packages/CoreDomain/
git commit -m "feat: CoreDomain package with all domain models"
```

---

### Task 4: CoreDomain Package — Repository Protocols

**Objective:** Port repository interfaces from Kotlin to Swift protocols.

**Files:**
- Create: `Packages/CoreDomain/Sources/CoreDomain/Repository/TelemetryRepository.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Repository/PreferencesRepository.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Repository/EntitlementRepository.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Repository/GeminiRepository.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Repository/ActivePlanHolder.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Repository/VehicleMotionHolder.swift`
- Create: `Packages/CoreDomain/Sources/CoreDomain/Repository/ConsentProvider.swift`

**Step 1: TelemetryRepository.swift**

```swift
import Foundation
import Combine

public protocol TelemetryRepository: AnyObject, Sendable {
    var telemetry: AnyPublisher<VehicleTelemetry, Never> { get }
    var connectionState: AnyPublisher<ConnectionState, Never> { get }
    func startScanning()
    func stopScanning()
    func connect(to device: ObdDevice) async throws
    func disconnect()
}

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case scanning
    case connecting
    case connected
    case error(String)
}
```

**Step 2: PreferencesRepository.swift**

```swift
import Foundation
import Combine

public struct UserPreferences: Sendable, Equatable {
    public var activeProfileId: String
    public var unitSystem: UnitSystem
    public var themeMode: ThemeMode
    public var geminiApiKey: String?
    public var aiCoachingEnabled: Bool
    public var googleMapsApiKey: String?
    public var useGoogleMaps: Bool
    public var chargerOccupancyAlerts: Bool
    public var googlePoiSearch: Bool
    public var isPro: Bool

    public init(
        activeProfileId: String = "ioniq5_2022_77kwh",
        unitSystem: UnitSystem = .metric,
        themeMode: ThemeMode = .system,
        geminiApiKey: String? = nil,
        aiCoachingEnabled: Bool = false,
        googleMapsApiKey: String? = nil,
        useGoogleMaps: Bool = false,
        chargerOccupancyAlerts: Bool = false,
        googlePoiSearch: Bool = false,
        isPro: Bool = false
    ) {
        self.activeProfileId = activeProfileId
        self.unitSystem = unitSystem
        self.themeMode = themeMode
        self.geminiApiKey = geminiApiKey
        self.aiCoachingEnabled = aiCoachingEnabled
        self.googleMapsApiKey = googleMapsApiKey
        self.useGoogleMaps = useGoogleMaps
        self.chargerOccupancyAlerts = chargerOccupancyAlerts
        self.googlePoiSearch = googlePoiSearch
        self.isPro = isPro
    }
}

public enum UnitSystem: String, Sendable, CaseIterable {
    case metric, imperial
}

public enum ThemeMode: String, Sendable, CaseIterable {
    case system, light, dark
}

public protocol PreferencesRepository: AnyObject, Sendable {
    var preferences: AnyPublisher<UserPreferences, Never> { get }
    func update(_ transform: (inout UserPreferences) -> Void)
}
```

**Step 3: Remaining protocols**

Port each from `core-domain/src/main/kotlin/com/fmz/ioniqtelemetry/domain/repository/`.

**Step 4: Commit**

```bash
git add Packages/CoreDomain/Sources/CoreDomain/Repository/
git commit -m "feat: CoreDomain repository protocols"
```

---

### Task 5: CoreData Package — SwiftData Entities

**Objective:** Port Room entities to SwiftData models.

**Files:**
- Create: `Packages/CoreData/Sources/CoreData/Entities/TripEntity.swift`
- Create: `Packages/CoreData/Sources/CoreData/Entities/SampleEntity.swift`
- Create: `Packages/CoreData/Sources/CoreData/Entities/ChargeSessionEntity.swift`
- Create: `Packages/CoreData/Sources/CoreData/Entities/SavedTripEntity.swift`
- Create: `Packages/CoreData/Sources/CoreData/Entities/SavedPlaceEntity.swift`
- Create: `Packages/CoreData/Sources/CoreData/Entities/ChargerEntity.swift`

**Step 1: TripEntity.swift**

```swift
import Foundation
import SwiftData

@Model
public final class TripEntity {
    @Attribute(.unique) public var id: UUID
    public var startTime: Date
    public var endTime: Date?
    public var startOdometerKm: Float?
    public var endOdometerKm: Float?
    public var distanceKm: Float
    public var energyKwh: Float
    public var avgEfficiencyKwhPer100km: Float?
    public var startSocPercent: Float?
    public var endSocPercent: Float?
    public var notes: String?
    public var startLatitude: Double?
    public var startLongitude: Double?
    public var endLatitude: Double?
    public var endLongitude: Double?

    @Relationship(deleteRule: .cascade, inverse: \SampleEntity.trip)
    public var samples: [SampleEntity]?

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        startOdometerKm: Float? = nil,
        endOdometerKm: Float? = nil,
        distanceKm: Float = 0,
        energyKwh: Float = 0,
        avgEfficiencyKwhPer100km: Float? = nil,
        startSocPercent: Float? = nil,
        endSocPercent: Float? = nil,
        notes: String? = nil,
        startLatitude: Double? = nil,
        startLongitude: Double? = nil,
        endLatitude: Double? = nil,
        endLongitude: Double? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.startOdometerKm = startOdometerKm
        self.endOdometerKm = endOdometerKm
        self.distanceKm = distanceKm
        self.energyKwh = energyKwh
        self.avgEfficiencyKwhPer100km = avgEfficiencyKwhPer100km
        self.startSocPercent = startSocPercent
        self.endSocPercent = endSocPercent
        self.notes = notes
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.endLatitude = endLatitude
        self.endLongitude = endLongitude
    }
}
```

**Step 2: SampleEntity.swift**

```swift
import Foundation
import SwiftData

@Model
public final class SampleEntity {
    @Attribute(.unique) public var id: UUID
    public var timestamp: Date
    public var speedKph: Float?
    public var socPercent: Float?
    public var powerKw: Float?
    public var packVoltage: Float?
    public var packCurrent: Float?
    public var cellDeltaMv: Float?
    public var maxCellTempC: Float?
    public var minCellTempC: Float?
    public var latitude: Double?
    public var longitude: Double?
    public var trip: TripEntity?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        speedKph: Float? = nil,
        socPercent: Float? = nil,
        powerKw: Float? = nil,
        packVoltage: Float? = nil,
        packCurrent: Float? = nil,
        cellDeltaMv: Float? = nil,
        maxCellTempC: Float? = nil,
        minCellTempC: Float? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.speedKph = speedKph
        self.socPercent = socPercent
        self.powerKw = powerKw
        self.packVoltage = packVoltage
        self.packCurrent = packCurrent
        self.cellDeltaMv = cellDeltaMv
        self.maxCellTempC = maxCellTempC
        self.minCellTempC = minCellTempC
        self.latitude = latitude
        self.longitude = longitude
    }
}
```

**Step 3: Remaining entities**

Port from `core-data/src/main/kotlin/com/fmz/ioniqtelemetry/data/db/Entities.kt`.

**Step 4: AppDatabase.swift (SwiftData container)**

```swift
import Foundation
import SwiftData

@MainActor
public final class AppDatabase: Sendable {
    public static let shared = AppDatabase()
    public let container: ModelContainer

    private init() {
        let schema = Schema([
            TripEntity.self,
            SampleEntity.self,
            ChargeSessionEntity.self,
            SavedTripEntity.self,
            SavedPlaceEntity.self,
            ChargerEntity.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
}
```

**Step 5: Commit**

```bash
git add Packages/CoreData/Sources/CoreData/Entities/
git commit -m "feat: SwiftData entities and database container"
```

---

### Task 6: CoreData Package — Repositories

**Objective:** Port repository implementations from Android Room to SwiftData.

**Files:**
- Create: `Packages/CoreData/Sources/CoreData/Repositories/TripLogRepository.swift`
- Create: `Packages/CoreData/Sources/CoreData/Repositories/ChargerRepository.swift`
- Create: `Packages/CoreData/Sources/CoreData/Repositories/SavedTripRepository.swift`
- Create: `Packages/CoreData/Sources/CoreData/Repositories/SavedPlaceRepository.swift`
- Create: `Packages/CoreData/Sources/CoreData/Repositories/BackupRepository.swift`
- Create: `Packages/CoreData/Sources/CoreData/Repositories/PreferencesRepositoryImpl.swift`

**Step 1: TripLogRepository.swift**

Port from `core-data/src/main/kotlin/com/fmz/ioniqtelemetry/data/repo/TripLogRepository.kt` (641 lines). Key methods:
- `startTrip()` — creates TripEntity, sets start time/odometer/SOC
- `endTrip()` — calculates distance (odometer delta, GPS haversine, speed×time), energy (SOC delta × capacity, power integration), saves
- `addSample()` — appends SampleEntity to active trip
- `getTrips()` — fetch all with pagination
- `getTripSummary()` — all-time stats
- `purgeOldTrips()` — 90-day free / 365-day pro retention
- `deleteTrip()` / `restoreTrip()`

**Step 2: ChargerRepository.swift**

Port from `core-data/src/main/kotlin/com/fmz/ioniqtelemetry/data/repo/ChargerRepository.kt` (191 lines). Key methods:
- `chargersNear(lat, lon, radius)` — OCM API fetch + cache
- `parsePricePerKwh()` — regex extract from UsageCost string
- Cache TTL: 7 days

**Step 3: Remaining repositories**

Port each from `core-data/src/main/kotlin/com/fmz/ioniqtelemetry/data/repo/`.

**Step 4: Package.swift for CoreData**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreData",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreData", targets: ["CoreData"])
    ],
    dependencies: [
        .package(path: "../CoreDomain")
    ],
    targets: [
        .target(name: "CoreData", dependencies: ["CoreDomain"]),
        .testTarget(name: "CoreDataTests", dependencies: ["CoreData"])
    ]
)
```

**Step 5: Commit**

```bash
git add Packages/CoreData/
git commit -m "feat: CoreData repositories with SwiftData persistence"
```

---

### Task 7: CoreRouting Package

**Objective:** Port pure Kotlin routing module to Swift.

**Files:**
- Create: `Packages/CoreRouting/Sources/CoreRouting/ConsumptionModel.swift`
- Create: `Packages/CoreRouting/Sources/CoreRouting/ChargeCurve.swift`
- Create: `Packages/CoreRouting/Sources/CoreRouting/Geohash.swift`
- Create: `Packages/CoreRouting/Sources/CoreRouting/Ioniq5Constants.swift`
- Create: `Packages/CoreRouting/Sources/CoreRouting/TripSolver.swift`
- Create: `Packages/CoreRouting/Sources/CoreRouting/RouteReplanner.swift`

**Step 1: Ioniq5Constants.swift**

Port vehicle catalog and OBD profile mappings. Must include:
- `vehicleNameFor(profileId: String) -> String`
- `usableKwhForProfile(profileId: String) -> Float`
- `obdProfileIdFor(vehicleId: String) -> String`
- 16 E-GMP vehicle entries (same as Android `EgmpVehicleCatalog`)

**Step 2: ConsumptionModel.swift**

Port consumption calculation with elevation awareness.

**Step 3: TripSolver.swift**

Port the charging stop optimization algorithm (283 lines in Android).

**Step 4: Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreRouting",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreRouting", targets: ["CoreRouting"])
    ],
    dependencies: [
        .package(path: "../CoreDomain")
    ],
    targets: [
        .target(name: "CoreRouting", dependencies: ["CoreDomain"])
    ]
)
```

**Step 5: Commit**

```bash
git add Packages/CoreRouting/
git commit -m "feat: CoreRouting package — trip solver and consumption model"
```

---

## Phase 3: OBD Communication (CoreOBD)

### Task 8: CoreOBD — Transport Layer

**Objective:** Port Bluetooth transport from Android SPP/BLE to iOS CoreBluetooth.

**Files:**
- Create: `Packages/CoreOBD/Sources/CoreOBD/Transport/ObdTransport.swift`
- Create: `Packages/CoreOBD/Sources/CoreOBD/Transport/BleTransport.swift`
- Create: `Packages/CoreOBD/Sources/CoreOBD/Transport/SppTransport.swift` (iOS equivalent via CoreBluetooth)

**Step 1: ObdTransport protocol**

```swift
import Foundation

public protocol ObdTransport: AnyObject, Sendable {
    var isConnected: Bool { get }
    var onDataReceived: ((Data) -> Void)? { get set }
    var onConnectionStateChanged: ((Bool) -> Void)? { get set }
    func connect() async throws
    func disconnect()
    func send(_ data: Data) async throws
}
```

**Step 2: BleTransport.swift**

Port from `core-obd/src/main/kotlin/com/fmz/ioniqtelemetry/obd/transport/BleTransport.kt` (277 lines). Key adaptations:
- Android `BluetoothGatt` → iOS `CBCentralManager` + `CBPeripheral`
- Service UUID: `FFE0`, Characteristic: `FFE1` (same for ELM327 clones)
- `CBPeripheralDelegate` for callbacks
- Handle `CBManagerState` (poweredOn check)

**Step 3: SppTransport equivalent**

iOS does not support Bluetooth SPP (Serial Port Profile) for non-MFi devices. The Vgate iCar Pro and most ELM327 clones support BLE. Strategy:
1. **Primary:** BLE transport (works on all iOS devices)
2. **Fallback:** WiFi OBD adapters (ELM327 WiFi) via `Network.framework` TCP socket
3. **No SPP:** Document that Bluetooth Classic SPP is not available on iOS

Create `Packages/CoreOBD/Sources/CoreOBD/Transport/WifiTransport.swift` for WiFi ELM327 adapters.

**Step 4: Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreOBD",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreOBD", targets: ["CoreOBD"])
    ],
    dependencies: [
        .package(path: "../CoreDomain")
    ],
    targets: [
        .target(name: "CoreOBD", dependencies: ["CoreDomain"])
    ]
)
```

**Step 5: Commit**

```bash
git add Packages/CoreOBD/
git commit -m "feat: CoreOBD transport layer — BLE + WiFi (no SPP on iOS)"
```

---

### Task 9: CoreOBD — ELM327 & ISO-TP

**Objective:** Port ELM327 initialization and ISO-TP reassembly.

**Files:**
- Create: `Packages/CoreOBD/Sources/CoreOBD/Elm/Elm327Initializer.swift`
- Create: `Packages/CoreOBD/Sources/CoreOBD/Elm/IsoTpReassembler.swift`

**Step 1: Elm327Initializer.swift**

Port from `core-obd/src/main/kotlin/com/fmz/ioniqtelemetry/obd/elm/Elm327Initializer.kt` (55 lines). Same AT command sequence:
- `ATZ` → delay 1000ms → `ATE0` → `ATL0` → `ATS0` → `ATH1` → `ATSP6` → `ATAL` → `ATCAF1` → `ATST64`

**Step 2: IsoTpReassembler.swift**

Port from `core-obd/src/main/kotlin/com/fmz/ioniqtelemetry/obd/elm/IsoTpReassembler.kt` (81 lines). Handle:
- Single frame (SF): `0X` prefix
- First frame (FF): `1X` prefix
- Consecutive frame (CF): `2X` prefix
- Flow control (FC): `3X` prefix

**Step 3: Commit**

```bash
git add Packages/CoreOBD/Sources/CoreOBD/Elm/
git commit -m "feat: ELM327 initializer and ISO-TP reassembler"
```

---

### Task 10: CoreOBD — Decoder & Polling

**Objective:** Port signal decoder and polling scheduler.

**Files:**
- Create: `Packages/CoreOBD/Sources/CoreOBD/Decoder/DecoderEngine.swift`
- Create: `Packages/CoreOBD/Sources/CoreOBD/Decoder/Profile.swift`
- Create: `Packages/CoreOBD/Sources/CoreOBD/Decoder/TelemetryAssembler.swift`
- Create: `Packages/CoreOBD/Sources/CoreOBD/Poll/PollingScheduler.swift`
- Create: `Packages/CoreOBD/Sources/CoreOBD/ObdManager.swift`

**Step 1: Profile.swift**

Port JSON profile structure. Same 5 vehicle profiles in `core-obd/src/main/assets/profiles/`:
- `ioniq5_2022_77kwh.json`
- `ioniq5_84kwh.json`
- `ioniq6_77kwh.json`
- `ev6_77kwh.json`
- `gv60_77kwh.json`

Convert to Swift structs or embed JSON files in package resources.

**Step 2: DecoderEngine.swift**

Port from `core-obd/src/main/kotlin/com/fmz/ioniqtelemetry/obd/decoder/DecoderEngine.kt` (55 lines). Formula evaluation:
- `A` = byte at startByte
- `B` = byte at startByte+1
- Formulas: `A`, `A-40`, `A/2`, `A*0.145`, `(A*256+B)/100`, etc.

**Step 3: TelemetryAssembler.swift**

Port from `core-obd/src/main/kotlin/com/fmz/ioniqtelemetry/obd/decoder/TelemetryAssembler.kt` (84 lines). Merges decoded signals into `VehicleTelemetry`.

**Step 4: PollingScheduler.swift**

Port from `core-obd/src/main/kotlin/com/fmz/ioniqtelemetry/obd/poll/PollingScheduler.kt` (160 lines). Same tiered polling:
- Tier 0 (fast): speed, SOC — 500ms
- Tier 1 (medium): power, temps — 2s
- Tier 2 (slow): TPMS, aux — 10s
- Diagnostic session `1003` on first contact per ECU

**Step 5: ObdManager.swift**

Port from `core-obd/src/main/kotlin/com/fmz/ioniqtelemetry/obd/ObdManager.kt` (264 lines). Manages:
- Profile loading from JSON
- Transport selection (BLE preferred, WiFi fallback)
- Connection state machine
- Reconnection logic with bond timeout handling

**Step 6: Commit**

```bash
git add Packages/CoreOBD/Sources/CoreOBD/Decoder/ Packages/CoreOBD/Sources/CoreOBD/Poll/ Packages/CoreOBD/Sources/CoreOBD/ObdManager.swift
git commit -m "feat: OBD decoder, polling scheduler, and manager"
```

---

## Phase 4: iOS App UI (SwiftUI)

### Task 11: App Entry & Root View

**Objective:** Create the main app entry point and root tab view matching Android's AppRoot.

**Files:**
- Create: `IoniqTelemetry/App/IoniqTelemetryApp.swift`
- Create: `IoniqTelemetry/App/AppRootView.swift`
- Create: `IoniqTelemetry/App/AppServices.swift`

**Step 1: IoniqTelemetryApp.swift**

```swift
import SwiftUI
import SwiftData
import CoreDomain
import CoreData
import CoreOBD
import CoreRouting
import CoreUI

@main
struct IoniqTelemetryApp: App {
    @State private var appServices = AppServices()
    @State private var selectedTab: AppTab = .dashboard

    var body: some Scene {
        WindowGroup {
            AppRootView(selectedTab: $selectedTab)
                .environment(appServices)
                .modelContainer(AppDatabase.shared.container)
                .task {
                    await appServices.initialize()
                }
        }
    }
}

enum AppTab: String, CaseIterable {
    case dashboard = "Dashboard"
    case trips = "Trips"
    case plan = "Plan"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .dashboard: return "gauge"
        case .trips: return "list.bullet"
        case .plan: return "map"
        case .settings: return "gear"
        }
    }
}
```

**Step 2: AppRootView.swift**

```swift
import SwiftUI

struct AppRootView: View {
    @Binding var selectedTab: AppTab
    @Environment(AppServices.self) private var services

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label(AppTab.dashboard.rawValue, systemImage: AppTab.dashboard.icon) }
                .tag(AppTab.dashboard)

            TripsView()
                .tabItem { Label(AppTab.trips.rawValue, systemImage: AppTab.trips.icon) }
                .tag(AppTab.trips)

            PlanView()
                .tabItem { Label(AppTab.plan.rawValue, systemImage: AppTab.plan.icon) }
                .tag(AppTab.plan)

            SettingsView()
                .tabItem { Label(AppTab.settings.rawValue, systemImage: AppTab.settings.icon) }
                .tag(AppTab.settings)
        }
        .tint(Color.electricTeal)
    }
}
```

**Step 3: AppServices.swift**

```swift
import Foundation
import CoreDomain
import CoreData
import CoreOBD
import CoreRouting

@Observable
@MainActor
final class AppServices {
    var telemetryRepository: TelemetryRepositoryImpl?
    var preferencesRepository: PreferencesRepositoryImpl?
    var tripLogRepository: TripLogRepository?
    var chargerRepository: ChargerRepository?
    var savedTripRepository: SavedTripRepository?
    var savedPlaceRepository: SavedPlaceRepository?
    var backupRepository: BackupRepository?
    var geminiRepository: GeminiRepositoryImpl?
    var obdManager: ObdManager?
    var entitlementRepository: EntitlementRepositoryImpl?

    func initialize() async {
        let container = AppDatabase.shared.container
        let context = container.mainContext

        preferencesRepository = PreferencesRepositoryImpl()
        tripLogRepository = TripLogRepository(modelContext: context)
        chargerRepository = ChargerRepository(modelContext: context)
        savedTripRepository = SavedTripRepository(modelContext: context)
        savedPlaceRepository = SavedPlaceRepository(modelContext: context)
        backupRepository = BackupRepository(modelContext: context)
        geminiRepository = GeminiRepositoryImpl()
        obdManager = ObdManager()
        entitlementRepository = EntitlementRepositoryImpl()

        telemetryRepository = TelemetryRepositoryImpl(
            obdManager: obdManager!,
            tripLogRepository: tripLogRepository!
        )
    }
}
```

**Step 4: Commit**

```bash
git add IoniqTelemetry/App/
git commit -m "feat: app entry point and root tab view"
```

---

### Task 12: Theme & Design System

**Objective:** Port the Material 3 dark theme to SwiftUI with iOS design principles.

**Files:**
- Create: `Packages/CoreUI/Sources/CoreUI/Theme/Theme.swift`
- Create: `Packages/CoreUI/Sources/CoreUI/Theme/Colors.swift`
- Create: `Packages/CoreUI/Sources/CoreUI/Theme/Typography.swift`

**Step 1: Colors.swift**

```swift
import SwiftUI

extension Color {
    // Brand accents — same as Android
    static let electricTeal = Color(red: 0.09, green: 0.91, blue: 0.76)  // #17E8C2
    static let electricTealLight = Color(red: 0.00, green: 0.42, blue: 0.35)  // #006B58

    // Dark surfaces — same as Android
    static let deepNavy = Color(red: 0.043, green: 0.071, blue: 0.125)  // #0B1220
    static let surfaceNavy = Color(red: 0.078, green: 0.114, blue: 0.188)  // #141D30
    static let surfaceVariant = Color(red: 0.15, green: 0.18, blue: 0.25)

    // Status colors
    static let greenOk = Color(red: 0.40, green: 0.73, blue: 0.42)  // #66BB6A
    static let greenOkDark = Color(red: 0.00, green: 0.44, blue: 0.24)  // #00703C
    static let amberWarn = Color(red: 1.00, green: 0.72, blue: 0.30)  // #FFB74D
    static let redAlert = Color(red: 0.94, green: 0.33, blue: 0.31)  // #EF5350

    // Adaptive colors
    static let background = Color(.systemBackground)
    static let secondaryBackground = Color(.secondarySystemBackground)
    static let label = Color(.label)
    static let secondaryLabel = Color(.secondaryLabel)
}
```

**Step 2: Theme.swift**

```swift
import SwiftUI

public struct IoniqTheme {
    public static func apply() {
        // Navigation bar appearance
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(Color.deepNavy)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance

        // Tab bar appearance
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(Color.deepNavy)
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }
}
```

**Step 3: Package.swift for CoreUI**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreUI",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreUI", targets: ["CoreUI"])
    ],
    dependencies: [
        .package(path: "../CoreDomain")
    ],
    targets: [
        .target(name: "CoreUI", dependencies: ["CoreDomain"])
    ]
)
```

**Step 4: Commit**

```bash
git add Packages/CoreUI/
git commit -m "feat: CoreUI theme — colors, typography, appearance"
```

---

### Task 13: Dashboard Screen

**Objective:** Port the Dashboard from Android Compose to SwiftUI.

**Files:**
- Create: `IoniqTelemetry/UI/Dashboard/DashboardView.swift`
- Create: `IoniqTelemetry/UI/Dashboard/Components/BatteryHeroCard.swift`
- Create: `IoniqTelemetry/UI/Dashboard/Components/MetricTiles.swift`
- Create: `IoniqTelemetry/UI/Dashboard/Components/TirePressureVisualizerCard.swift`
- Create: `IoniqTelemetry/UI/Dashboard/Components/ThermalTipCard.swift`
- Create: `IoniqTelemetry/UI/Dashboard/DashboardViewModel.swift`

**Step 1: DashboardViewModel.swift**

```swift
import Foundation
import CoreDomain
import Combine

@MainActor
@Observable
final class DashboardViewModel {
    var telemetry: VehicleTelemetry = VehicleTelemetry()
    var connectionState: ConnectionState = .disconnected
    var vehicleName: String = "IONIQ 5"
    var isPro: Bool = false
    var aiCoachingEnabled: Bool = false
    var hasGeminiKey: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private let telemetryRepository: TelemetryRepository?
    private let preferencesRepository: PreferencesRepository?

    init(telemetryRepository: TelemetryRepository?, preferencesRepository: PreferencesRepository?) {
        self.telemetryRepository = telemetryRepository
        self.preferencesRepository = preferencesRepository
        setupBindings()
    }

    private func setupBindings() {
        telemetryRepository?.telemetry
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.telemetry = $0 }
            .store(in: &cancellables)

        telemetryRepository?.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.connectionState = $0 }
            .store(in: &cancellables)

        preferencesRepository?.preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in
                self?.isPro = prefs.isPro
                self?.aiCoachingEnabled = prefs.aiCoachingEnabled
                self?.hasGeminiKey = !(prefs.geminiApiKey?.isEmpty ?? true)
                self?.vehicleName = Ioniq5Constants.vehicleNameFor(prefs.activeProfileId)
            }
            .store(in: &cancellables)
    }
}
```

**Step 2: BatteryHeroCard.swift**

Port from `app/src/main/kotlin/com/fmz/ioniqtelemetry/ui/dashboard/components/BatteryHeroCard.kt` (187 lines). Key elements:
- SOC ring: 120dp size, 12dp stroke, start 160°, sweep 220°, gap 140° at bottom
- Percentage: 32sp Bold, -1.5 letter spacing
- Stats row: BMS SOC, HEALTH SOH, PACK TEMP
- Charging chip with method + kW

Use SwiftUI `Circle` with `trim(from:to:)` and `rotationEffect` for the ring.

**Step 3: MetricTiles.swift**

Port from `app/src/main/kotlin/com/fmz/ioniqtelemetry/ui/dashboard/components/MetricTiles.kt` (177 lines). Tiles:
- PowerTile (Bolt icon, REGEN badge when speed > 10 && power < 0)
- CellDeltaTile (ShowChart icon)
- HvVoltageTile (BatteryChargingFull icon)
- AuxBatteryTile (BatteryFull icon)

**Step 4: TirePressureVisualizerCard.swift**

Port from `app/src/main/kotlin/com/fmz/ioniqtelemetry/ui/dashboard/components/TirePressureVisualizerCard.kt` (376 lines). 2D layout with FL/RL left, car center, FR/RR right. Low pressure < 220 kPa triggers red.

**Step 5: DashboardView.swift**

```swift
import SwiftUI
import CoreDomain
import CoreUI

struct DashboardView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel: DashboardViewModel?
    @State private var showCopilot = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let vm = viewModel {
                        // Header
                        HStack {
                            Text(vm.vehicleName.uppercased())
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            ConnectionBadge(state: vm.connectionState)
                        }
                        .padding(.horizontal)

                        BatteryHeroCard(telemetry: vm.telemetry)

                        MetricTiles(telemetry: vm.telemetry)

                        TirePressureVisualizerCard(telemetry: vm.telemetry)

                        ThermalTipCard(telemetry: vm.telemetry)
                    }
                }
                .padding(.vertical)
            }
            .background(Color.deepNavy)
            .navigationTitle("Dashboard")
            .toolbar {
                if viewModel?.isPro == true &&
                   viewModel?.aiCoachingEnabled == true &&
                   viewModel?.hasGeminiKey == true {
                    Button {
                        showCopilot = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                }
            }
            .sheet(isPresented: $showCopilot) {
                CopilotView()
            }
        }
        .task {
            viewModel = DashboardViewModel(
                telemetryRepository: services.telemetryRepository,
                preferencesRepository: services.preferencesRepository
            )
        }
    }
}
```

**Step 6: Commit**

```bash
git add IoniqTelemetry/UI/Dashboard/
git commit -m "feat: Dashboard screen with battery hero, metric tiles, tire visualizer"
```

---

### Task 14: Trips Screen

**Objective:** Port Trip History from Android Compose to SwiftUI.

**Files:**
- Create: `IoniqTelemetry/UI/Trips/TripsView.swift`
- Create: `IoniqTelemetry/UI/Trips/TripDetailView.swift`
- Create: `IoniqTelemetry/UI/Trips/TripsViewModel.swift`

**Step 1: TripsViewModel.swift**

Port from Android `TripsScreen.kt` logic. Key features:
- Trip list with LazyVStack
- All-time summary header (trips count, total distance, avg efficiency)
- Swipe-to-delete with undo
- Monthly grouping
- Empty state (no "Connect Adapter" button)

**Step 2: TripCard component**

Port from `TripsScreen.kt` — matches ChargeSessionCard pattern:
- Elevated card, 16dp padding, 10dp spacing
- Header: 36dp icon in colored circle + date + subtitle (duration) | Delete (red)
- HorizontalDivider
- Stats row: uppercase labels, bold values
- SOC bar at bottom

**Step 3: TripsView.swift**

```swift
import SwiftUI
import CoreDomain
import SwiftData

struct TripsView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \TripEntity.startTime, order: .reverse) private var trips: [TripEntity]
    @State private var showDeleteAlert = false
    @State private var tripToDelete: TripEntity?

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty {
                    EmptyTripsView()
                } else {
                    tripList
                }
            }
            .background(Color.deepNavy)
            .navigationTitle("Trips")
        }
    }

    private var tripList: some View {
        List {
            // All-time summary
            TripSummaryHeader(trips: trips)
                .listRowBackground(Color.surfaceNavy)

            // Grouped by month
            ForEach(groupedByMonth, id: \.key) { month, monthTrips in
                Section(header: Text(month).foregroundStyle(.secondary)) {
                    ForEach(monthTrips) { trip in
                        TripCard(trip: trip)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    tripToDelete = trip
                                    showDeleteAlert = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listRowBackground(Color.surfaceNavy)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .alert("Delete Trip?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let trip = tripToDelete {
                    deleteTrip(trip)
                }
            }
        }
    }

    private var groupedByMonth: [(key: String, value: [TripEntity])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return Dictionary(grouping: trips) { formatter.string(from: $0.startTime) }
            .sorted { $0.key > $1.key }
    }

    private func deleteTrip(_ trip: TripEntity) {
        // Delete with undo snackbar
    }
}
```

**Step 4: TripDetailView.swift**

Port from Android `TripDetailScreen.kt`. Shows:
- Route map with polyline
- Elevation chart
- Speed chart
- SOC chart
- Power chart
- All samples in list

**Step 5: Commit**

```bash
git add IoniqTelemetry/UI/Trips/
git commit -m "feat: Trips screen with trip cards, detail view, swipe-to-delete"
```

---

### Task 15: Plan Screen (Trip Planner)

**Objective:** Port the Trip Planner from Android Compose to SwiftUI.

**Files:**
- Create: `IoniqTelemetry/UI/Plan/PlanView.swift`
- Create: `IoniqTelemetry/UI/Plan/PlanViewModel.swift`
- Create: `IoniqTelemetry/UI/Plan/Components/RouteBuilderCard.swift`
- Create: `IoniqTelemetry/UI/Plan/Components/BatteryParametersCard.swift`
- Create: `IoniqTelemetry/UI/Plan/Components/ItineraryTimeline.swift`
- Create: `IoniqTelemetry/UI/Plan/Components/AiPlanCard.swift`
- Create: `IoniqTelemetry/UI/Plan/Components/NearbyChargersSection.swift`
- Create: `IoniqTelemetry/UI/Plan/Components/AlternativeChargerDialog.swift`

**Step 1: PlanViewModel.swift**

Port from `PlanViewModel.kt` (654 lines). Key features:
- Geocoding via `GeocodingRepository` (Nominatim or Google Places)
- Trip planning via `TripSolver` (CoreRouting)
- AI natural language parsing via `GeminiRepository`
- Saved trips and favorite places
- Live charger occupancy

**Step 2: RouteBuilderCard.swift**

Port from `RouteBuilderCard.kt` (512 lines). Features:
- Origin/destination text fields with POI search
- Swap button
- Departure time picker
- "Plan Route" button

**Step 3: BatteryParametersCard.swift**

Port from `BatteryParametersCard.kt` (246 lines). Features:
- Departure SOC slider
- Arrival reserve target chips (10%, 20%, 30%)
- Current-value pill badge

**Step 4: ItineraryTimeline.swift**

Port from `ItineraryTimeline.kt` (485 lines). Features:
- Vertical timeline with departure, stops, arrival
- Each stop: charger name, power, price, duration
- Distance and time for each leg

**Step 5: PlanView.swift**

```swift
import SwiftUI
import CoreDomain

struct PlanView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel: PlanViewModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let vm = viewModel {
                        PlanHeader()

                        if vm.isPro && vm.hasGeminiKey && vm.aiCoachingEnabled {
                            AiPlanCard(viewModel: vm)
                        }

                        RouteBuilderCard(viewModel: vm)

                        BatteryParametersCard(viewModel: vm)

                        if let plan = vm.currentPlan {
                            ItineraryTimeline(plan: plan)
                        }

                        NearbyChargersSection(viewModel: vm)

                        FavoriteTripsSection(viewModel: vm)
                    }
                }
                .padding()
            }
            .background(Color.deepNavy)
            .navigationTitle("Plan")
        }
        .task {
            viewModel = PlanViewModel(
                tripSolver: TripSolver(),
                chargerRepository: services.chargerRepository,
                savedTripRepository: services.savedTripRepository,
                savedPlaceRepository: services.savedPlaceRepository,
                geminiRepository: services.geminiRepository,
                preferencesRepository: services.preferencesRepository
            )
        }
    }
}
```

**Step 6: Commit**

```bash
git add IoniqTelemetry/UI/Plan/
git commit -m "feat: Trip Planner with route builder, battery params, itinerary timeline"
```

---

### Task 16: Settings Screen

**Objective:** Port Settings from Android Compose to SwiftUI.

**Files:**
- Create: `IoniqTelemetry/UI/Settings/SettingsView.swift`
- Create: `IoniqTelemetry/UI/Settings/SettingsViewModel.swift`
- Create: `IoniqTelemetry/UI/Settings/Components/VehicleProfileCard.swift`
- Create: `IoniqTelemetry/UI/Settings/Components/GeminiAiSettingsCard.swift`
- Create: `IoniqTelemetry/UI/Settings/Components/RoutingProviderCard.swift`
- Create: `IoniqTelemetry/UI/Settings/Components/UnitSystemCard.swift`

**Step 1: SettingsViewModel.swift**

Port from Android `SettingsScreen.kt` (1578 lines). Key features:
- OBD device pairing and management
- Vehicle profile selection (16 E-GMP vehicles, dialog-based picker)
- Unit system toggle (Metric/Imperial)
- Theme mode (System/Light/Dark)
- Gemini API key with eye-icon toggle
- Google Maps API key
- Routing provider toggles
- Backup/restore
- Console access

**Step 2: VehicleProfileCard.swift**

Port from `EgmpVehicleCatalog.kt` + `SettingsScreen.kt`. Dialog-based picker:
- Compact tappable summary showing current vehicle
- AlertDialog with grouped list (Hyundai, Kia, Genesis)
- Each row: model name + kWh badge + checkmark

**Step 3: GeminiAiSettingsCard.swift**

Port from `SettingsScreen.kt`. Features:
- Always visible, PRO badge for non-Pro
- "Unlock AI Features with Pro" button for non-Pro
- API key field with PasswordVisualTransformation + eye toggle
- Enable AI coaching toggle
- AI Assistant description matching actual features

**Step 4: SettingsView.swift**

```swift
import SwiftUI
import CoreDomain

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel: SettingsViewModel?

    var body: some View {
        NavigationStack {
            List {
                if let vm = viewModel {
                    Section("Vehicle") {
                        VehicleProfileCard(viewModel: vm)
                    }

                    Section("OBD Adapter") {
                        ObdDeviceCard(viewModel: vm)
                    }

                    Section("AI Assistant") {
                        GeminiAiSettingsCard(viewModel: vm)
                    }

                    Section("Routing") {
                        RoutingProviderCard(viewModel: vm)
                    }

                    Section("Units") {
                        UnitSystemCard(viewModel: vm)
                    }

                    Section("Appearance") {
                        ThemeCard(viewModel: vm)
                    }

                    Section("Data") {
                        BackupCard(viewModel: vm)
                    }

                    Section("Advanced") {
                        Button("Console") {
                            // Navigate to console
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.deepNavy)
            .navigationTitle("Settings")
        }
        .task {
            viewModel = SettingsViewModel(
                preferencesRepository: services.preferencesRepository,
                obdManager: services.obdManager,
                backupRepository: services.backupRepository,
                entitlementRepository: services.entitlementRepository
            )
        }
    }
}
```

**Step 5: Commit**

```bash
git add IoniqTelemetry/UI/Settings/
git commit -m "feat: Settings screen with vehicle picker, AI card, routing, units"
```

---

### Task 17: Paywall Screen

**Objective:** Port Paywall from Android Compose to SwiftUI with StoreKit 2.

**Files:**
- Create: `IoniqTelemetry/UI/Paywall/PaywallView.swift`
- Create: `IoniqTelemetry/UI/Paywall/PaywallViewModel.swift`

**Step 1: PaywallViewModel.swift**

Port from Android `PaywallScreen.kt` (592 lines). Key features:
- StoreKit 2 `Product.products(for:)`
- Product IDs: `ioniq_pro_monthly_sub`, `ioniq_pro_yearly_sub`, `ioniq_pro_lifetime`
- Comparison table matching real gates
- "Unlock Pro" title (no Ioniq branding)
- Subtitle: "Supports all E-GMP vehicles"

**Step 2: PaywallView.swift**

```swift
import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel: PaywallViewModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.electricTeal)
                        Text("Unlock Pro")
                            .font(.largeTitle.bold())
                        Text("Supports all E-GMP vehicles.")
                            .foregroundStyle(.secondary)
                    }

                    // Feature list
                    VStack(alignment: .leading, spacing: 12) {
                        FeatureRow(icon: "sparkles", text: "AI Assistant")
                        FeatureRow(icon: "xmark.circle", text: "Remove Ads")
                        FeatureRow(icon: "bell", text: "Charger Occupancy Alerts")
                        FeatureRow(icon: "map", text: "Live Charger Availability")
                        FeatureRow(icon: "calendar", text: "365-Day Trip Retention")
                    }
                    .padding()

                    // Products
                    if let products = viewModel?.products {
                        ForEach(products) { product in
                            ProductButton(product: product) {
                                Task { await viewModel?.purchase(product) }
                            }
                        }
                    }

                    // Restore
                    Button("Restore Purchases") {
                        Task { await viewModel?.restore() }
                    }
                    .foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color.deepNavy)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            viewModel = PaywallViewModel(
                entitlementRepository: services.entitlementRepository
            )
            await viewModel?.loadProducts()
        }
    }
}
```

**Step 3: Commit**

```bash
git add IoniqTelemetry/UI/Paywall/
git commit -m "feat: Paywall with StoreKit 2 subscriptions"
```

---

### Task 18: Copilot Dialog

**Objective:** Port AI Copilot from Android Compose to SwiftUI.

**Files:**
- Create: `IoniqTelemetry/UI/Components/CopilotView.swift`
- Create: `IoniqTelemetry/UI/Components/CopilotViewModel.swift`

**Step 1: CopilotViewModel.swift**

Port from Android `CopilotDialog.kt` (681 lines). Key features:
- Gemini API integration
- Voice input (Speech framework)
- TTS output (AVSpeechSynthesizer)
- Navigate button with keyword detection
- Charger list with occupancy badges
- No "Gemini" branding — "AI Assistant"

**Step 2: CopilotView.swift**

```swift
import SwiftUI
import Speech
import AVFoundation

struct CopilotView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel: CopilotViewModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                // Chat messages
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let messages = viewModel?.messages {
                            ForEach(messages) { message in
                                ChatBubble(message: message)
                            }
                        }
                    }
                    .padding()
                }

                // Input area
                HStack {
                    TextField("Ask AI Assistant...", text: Binding(
                        get: { viewModel?.inputText ?? "" },
                        set: { viewModel?.inputText = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Button {
                        Task { await viewModel?.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(viewModel?.inputText.isEmpty ?? true)

                    Button {
                        viewModel?.toggleVoiceInput()
                    } label: {
                        Image(systemName: viewModel?.isListening == true ? "mic.fill" : "mic")
                            .font(.title2)
                    }
                }
                .padding()
            }
            .background(Color.deepNavy)
            .navigationTitle("AI Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            viewModel = CopilotViewModel(
                geminiRepository: services.geminiRepository,
                telemetryRepository: services.telemetryRepository,
                chargerRepository: services.chargerRepository
            )
        }
    }
}
```

**Step 3: Commit**

```bash
git add IoniqTelemetry/UI/Components/
git commit -m "feat: AI Copilot dialog with voice input and TTS"
```

---

## Phase 5: Background Services

### Task 19: Connected Car Service

**Objective:** Port the foreground service from Android to iOS background processing.

**Files:**
- Create: `IoniqTelemetry/Service/ConnectedCarService.swift`
- Create: `IoniqTelemetry/Service/DriveMonitor.swift`
- Create: `IoniqTelemetry/Service/ChargeAlertMonitor.swift`
- Create: `IoniqTelemetry/Service/OccupancyAlertMonitor.swift`
- Create: `IoniqTelemetry/Service/LiveReplanMonitor.swift`
- Create: `IoniqTelemetry/Service/ParkedStateEvaluator.swift`
- Create: `IoniqTelemetry/Service/TirePressureMonitor.swift`
- Create: `IoniqTelemetry/Service/BatteryHealthEstimator.swift`

**Step 1: ConnectedCarService.swift**

Port from `ConnectedCarService.kt` (798 lines). iOS adaptations:
- Android `Service` → iOS `BGProcessingTask` + `BGAppRefreshTask`
- CoreBluetooth background mode (`bluetooth-central` in Info.plist)
- `CBCentralManager` with `CBCentralManagerOptionRestoreIdentifierKey`
- State restoration for background OBD connection

**Step 2: DriveMonitor.swift**

Port from `DriveMonitor.kt` (304 lines). Trip detection:
- Activity Recognition → iOS `CMMotionActivityManager`
- GPS fallback: `CLLocationManager` with `desiredAccuracy = kCLLocationAccuracyBestForNavigation`
- 4-trigger OR chain: motion activity >75% || GPS 60m from anchor || OBD connected >30s || no location permission
- Minimum distance: 1 km

**Step 3: ChargeAlertMonitor.swift**

Port from `ChargeAlertMonitor.kt` (56 lines). Double gate:
- GPS speed ≤ 3 km/h or null
- Activity Recognition `!inVehicle` (iOS: `CMMotionActivity.automotive`)

**Step 4: Remaining monitors**

Port each from Android `service/` directory.

**Step 5: Info.plist background modes**

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>fetch</string>
    <string>location</string>
    <string>processing</string>
</array>
```

**Step 6: Commit**

```bash
git add IoniqTelemetry/Service/ IoniqTelemetry/Resources/Info.plist
git commit -m "feat: background services — connected car, drive monitor, charge alerts"
```

---

## Phase 6: CarPlay

### Task 20: CarPlay Scene Delegate & Templates

**Objective:** Create CarPlay UI equivalent to Android Auto.

**Files:**
- Create: `IoniqTelemetry/CarPlay/CarPlaySceneDelegate.swift`
- Create: `IoniqTelemetry/CarPlay/Templates/DashboardTemplate.swift`
- Create: `IoniqTelemetry/CarPlay/Templates/ChargingTemplate.swift`
- Create: `IoniqTelemetry/CarPlay/Templates/TripHistoryTemplate.swift`
- Create: `IoniqTelemetry/CarPlay/Templates/TripPlanTemplate.swift`
- Create: `IoniqTelemetry/CarPlay/Templates/ChargerListTemplate.swift`
- Create: `IoniqTelemetry/CarPlay/Templates/BatteryHealthTemplate.swift`

**Step 1: CarPlaySceneDelegate.swift**

```swift
import CarPlay
import CoreDomain
import CoreUI

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let dashboard = DashboardTemplate.make()
        interfaceController.setRootTemplate(dashboard, animated: true)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }
}
```

**Step 2: DashboardTemplate.swift**

Port from `auto/src/main/kotlin/com/fmz/ioniqtelemetry/auto/DashboardScreen.kt` (246 lines). CarPlay equivalents:
- Android `Screen` → iOS `CPTemplate`
- `ListTemplate` → `CPListTemplate`
- `GridTemplate` → `CPGridTemplate`
- `PaneTemplate` → `CPAlertTemplate`

Dashboard shows:
- SOC ring (via custom `CPDashboardTemplate` or `CPGridTemplate` with image)
- Power, CellDelta, HV Voltage, Aux Battery tiles
- Tire pressure summary

**Step 3: ChargingTemplate.swift**

Port from `auto/src/main/kotlin/com/fmz/ioniqtelemetry/auto/ChargingScreen.kt` (132 lines). Shows:
- Charging status
- Power kW
- Time to 80%/100%
- SOC progress bar

**Step 4: TripHistoryTemplate.swift**

Port from `auto/src/main/kotlin/com/fmz/ioniqtelemetry/auto/TripHistoryScreen.kt` (104 lines). `CPListTemplate` with trip items.

**Step 5: TripPlanTemplate.swift**

Port from `auto/src/main/kotlin/com/fmz/ioniqtelemetry/auto/TripPlanScreen.kt` (183 lines). `CPListTemplate` with itinerary items.

**Step 6: Info.plist CarPlay configuration**

```xml
<key>UIApplicationSceneManifest</key>
<dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <true/>
    <key>UISceneConfigurations</key>
    <dict>
        <key>CPTemplateApplicationSceneSessionRoleApplication</key>
        <dict>
            <key>UISceneClassName</key>
            <string>CPTemplateApplicationScene</string>
            <key>UISceneConfigurationName</key>
            <string>CarPlay</string>
            <key>UISceneDelegateClassName</key>
            <string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
        </dict>
    </dict>
</dict>
```

**Step 7: Commit**

```bash
git add IoniqTelemetry/CarPlay/ IoniqTelemetry/Resources/Info.plist
git commit -m "feat: CarPlay templates — dashboard, charging, trips, plan, chargers"
```

---

## Phase 7: Polish & Release

### Task 21: Navigation Hand-off

**Objective:** Port Google Maps / Apple Maps navigation hand-off from Android.

**Files:**
- Create: `IoniqTelemetry/Navigation/MapsNavigation.swift`

**Step 1: MapsNavigation.swift**

```swift
import Foundation
import MapKit
import CoreLocation

public enum MapsNavigation {
    /// Open Apple Maps with navigation to destination
    public static func navigateTo(destination: String, latitude: Double? = nil, longitude: Double? = nil) {
        if let lat = latitude, let lon = longitude {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let placemark = MKPlacemark(coordinate: coordinate)
            let mapItem = MKMapItem(placemark: placemark)
            mapItem.name = destination
            mapItem.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
            ])
        } else {
            // Geocode the destination string
            let geocoder = CLGeocoder()
            geocoder.geocodeAddressString(destination) { placemarks, error in
                guard let placemark = placemarks?.first,
                      let location = placemark.location else { return }
                let mapItem = MKMapItem(placemark: MKPlacemark(placemark: placemark))
                mapItem.name = destination
                mapItem.openInMaps(launchOptions: [
                    MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
                ])
            }
        }
    }

    /// Open Google Maps if installed, else Apple Maps
    public static func navigateWithGoogleMaps(destination: String) {
        let encoded = destination.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "comgooglemaps://?daddr=\(encoded)&directionsmode=driving"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            navigateTo(destination: destination)
        }
    }
}
```

**Step 2: Commit**

```bash
git add IoniqTelemetry/Navigation/
git commit -m "feat: navigation hand-off to Apple/Google Maps"
```

---

### Task 22: Backup/Restore

**Objective:** Port backup/restore from Android to iOS.

**Files:**
- Create: `Packages/CoreData/Sources/CoreData/Repositories/BackupRepository.swift`

**Step 1: BackupRepository.swift**

Port from `core-data/src/main/kotlin/com/fmz/ioniqtelemetry/data/repo/BackupRepository.kt` (363 lines). Key features:
- Export to JSON (Moshi → Swift `Codable`)
- Import via manual JSON parsing (same org.json approach, but Swift native)
- Entities: trips, samples, charge sessions, saved plans, saved places, settings
- `activeProfileId` must be included in backup

**Step 2: File export via UIActivityViewController**

```swift
import SwiftUI

struct BackupExporter {
    static func export(data: Data, filename: String) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: tempURL)
        let activityVC = UIActivityViewController(
            activityItems: [tempURL],
            applicationActivities: nil
        )
        // Present from root view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
}
```

**Step 3: Commit**

```bash
git add Packages/CoreData/Sources/CoreData/Repositories/BackupRepository.swift
git commit -m "feat: backup/restore with JSON export/import"
```

---

### Task 23: App Store Preparation

**Objective:** Prepare for TestFlight and App Store submission.

**Files:**
- Create: `fastlane/Fastfile` (optional)
- Modify: `project.yml` — add release configuration

**Step 1: Version bump configuration**

```yaml
# In project.yml settings:
settings:
  base:
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: "1"
    ITSAppUsesNonExemptEncryption: false
```

**Step 2: Archive and upload script**

```bash
#!/bin/bash
# scripts/upload_testflight.sh
set -e

# Bump build number
agvtool next-version -all

# Archive
xcodebuild -project IoniqTelemetry.xcodeproj \
  -scheme IoniqTelemetry \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath ./build/IoniqTelemetry.xcarchive \
  archive

# Export IPA
xcodebuild -exportArchive \
  -archivePath ./build/IoniqTelemetry.xcarchive \
  -exportPath ./build \
  -exportOptionsPlist ExportOptions.plist

# Upload to TestFlight
xcrun altool --upload-app \
  --type ios \
  --file ./build/IoniqTelemetry.ipa \
  --apiKey "$APP_STORE_CONNECT_API_KEY" \
  --apiIssuer "$APP_STORE_CONNECT_API_ISSUER"
```

**Step 3: Commit**

```bash
git add scripts/upload_testflight.sh ExportOptions.plist
git commit -m "chore: TestFlight upload script"
```

---

## Design Principles Applied

### iOS Human Interface Guidelines (Latest)

1. **SF Symbols** — All icons use SF Symbols 6 (iOS 17+) for native feel
2. **Dynamic Type** — All text scales with user's preferred content size
3. **Dark Mode** — Default dark theme (same as Android), respects system setting
4. **Haptic Feedback** — `UIImpactFeedbackGenerator` for button taps, `UINotificationFeedbackGenerator` for alerts
5. **Safe Area** — All content respects safe area insets
6. **Navigation** — `NavigationStack` with large titles for iOS 17+ patterns
7. **Sheets** — `.sheet` for modals (Copilot, Paywall, dialogs)
8. **Lists** — `List` with `insetGrouped` style for Settings, `plain` for Trips
9. **Swipe Actions** — Native `swipeActions` for delete in Trips list
10. **Context Menus** — `contextMenu` for secondary actions

### Android → iOS Mapping

| Android (Compose) | iOS (SwiftUI) | Notes |
|---|---|---|
| `Scaffold` + `NavigationBar` | `TabView` + `navigationTitle` | iOS tab bar is native |
| `ElevatedCard` | `List` row or `GroupBox` | iOS uses grouped lists |
| `FilterChip` | `Picker` with `.segmented` or custom capsule | iOS segmented control |
| `AlertDialog` | `.alert` | Native iOS alert |
| `SwipeToDismissBox` | `swipeActions` | Native iOS swipe |
| `ExtendedFloatingActionButton` | Toolbar button or overlay | iOS doesn't use FABs |
| `HorizontalDivider` | `Divider` | Native iOS |
| `LazyColumn` | `List` or `LazyVStack` in `ScrollView` | iOS List is preferred |
| `OutlinedCard` | `GroupBox` | Similar bordered container |
| `Snackbar` | Custom overlay or `.toast` (3rd party) | iOS has no native snackbar |

### Color Palette (Identical to Android)

| Name | Hex | Usage |
|---|---|---|
| ElectricTeal | #17E8C2 | Primary accent, SOC ring, buttons |
| DeepNavy | #0B1220 | Background |
| SurfaceNavy | #141D30 | Card surfaces |
| GreenOk | #66BB6A | Connected, charging, healthy |
| AmberWarn | #FFB74D | Caution, cold battery |
| RedAlert | #EF5350 | Error, low tire, disconnected |

---

## Summary of Port Scope

| Android Module | iOS Equivalent | Lines (approx) |
|---|---|---|
| `core-domain` (12 files) | `CoreDomain` package | ~500 |
| `core-data` (15 files) | `CoreData` package | ~2,000 |
| `core-routing` (7 files) | `CoreRouting` package | ~800 |
| `core-obd` (14 files) | `CoreOBD` package | ~1,200 |
| `core-ui` (2 files) | `CoreUI` package | ~200 |
| `app` UI (20 files) | `IoniqTelemetry/UI/` | ~5,000 |
| `app` services (8 files) | `IoniqTelemetry/Service/` | ~1,200 |
| `auto` (11 files) | `IoniqTelemetry/CarPlay/` | ~800 |
| **Total** | | **~12,000** |

---

## Execution Handoff

**Plan complete and saved. Ready to execute using subagent-driven-development — I'll dispatch a fresh subagent per task with two-stage review (spec compliance then code quality). Shall I proceed?**

Key implementation notes:
1. **Start with Phase 1-2** (scaffolding + core packages) — these have no UI dependencies
2. **Phase 3 (OBD)** can be developed with a mock transport before real hardware testing
3. **Phase 4 (UI)** can be built with `@Preview` mocks using sample telemetry data
4. **Phase 5 (Background)** requires real device testing with an ELM327 adapter
5. **Phase 6 (CarPlay)** requires a CarPlay-capable head unit or simulator
6. **App icon** is generated from the same vector source as Android — 100% brand match