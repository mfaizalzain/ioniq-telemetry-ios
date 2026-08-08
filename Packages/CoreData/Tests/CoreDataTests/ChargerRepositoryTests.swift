import Combine
import CoreDomain
import Foundation
import SwiftData
import Testing
@testable import CoreData

/// Covers the source-switch contract: switching providers must take effect
/// immediately, but must never blank the charger list when the new provider
/// can't be reached — the old rows fall back instead.
@Suite("ChargerRepository", .serialized)
struct ChargerRepositoryTests {

    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requestCount = 0
        nonisolated(unsafe) static var responseBody = Data("[]".utf8)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: Schema([ChargerEntity.self]), configurations: config)
    }

    private func entity(
        id: String,
        name: String,
        lat: Double = 4.2,
        lon: Double = 101.1,
        cachedAt: Date = Date()
    ) -> ChargerEntity {
        ChargerEntity(
            id: id,
            name: name,
            lat: lat,
            lon: lon,
            geohash: Geohash.encode(lat: lat, lon: lon, precision: 6),
            maxPowerKw: 150,
            connectorsJson: "[]",
            isOperational: true,
            cachedAt: cachedAt
        )
    }

    private func ocmResponse(id: Int, title: String) -> Data {
        Data("""
        [
          {
            "ID": \(id),
            "AddressInfo": { "Title": "\(title)", "Latitude": 4.2, "Longitude": 101.1, "Town": "Tapah" },
            "Connections": [ { "ConnectionTypeID": 33, "PowerKW": 150.0, "Quantity": 2 } ],
            "OperatorInfo": { "Title": "Petronas" },
            "StatusType": { "IsOperational": true }
          }
        ]
        """.utf8)
    }

    private let center = LatLon(lat: 4.2, lon: 101.1)

    @Test("a failed refresh after a source switch falls back to the old source's rows")
    func failedRefreshKeepsOldRows() async throws {
        StubProtocol.requestCount = 0
        let context = ModelContext(makeContainer())
        context.insert(entity(id: "ocm-1", name: "Petronas Tapah"))
        try context.save()

        // Switching to Google Places without a key: the refresh throws before
        // any network call, so the stub stays untouched.
        let repo = ChargerRepository(
            modelContext: context,
            apiKey: { "k" },
            source: { .googlePlaces },
            googleApiKey: { "" },
            session: makeSession()
        )
        var servingCached = false
        let cancellable = repo.servingCachedData.sink { servingCached = $0 }
        defer { cancellable.cancel() }

        let chargers = try await repo.chargersNear(center: center)

        #expect(chargers.map(\.id) == ["ocm-1"], "old rows must still show when the new source can't refresh")
        #expect(servingCached, "the UI must warn that it's serving cached data")
        #expect(StubProtocol.requestCount == 0)
    }

    @Test("Google nearby search uses Android's 10 km circle and keeps connector-unknown stations")
    func googleNearbyMatchesAndroidPolicy() async throws {
        StubProtocol.requestCount = 0
        StubProtocol.responseBody = Data(#"""
        {
          "places": [
            {
              "id": "places/unknown-connectors",
              "displayName": { "text": "Unknown Connector Station" },
              "location": { "latitude": 4.2, "longitude": 101.1 },
              "evChargeOptions": { "connectorAggregation": [] }
            }
          ]
        }
        """#.utf8)

        let context = ModelContext(makeContainer())
        let repo = ChargerRepository(
            modelContext: context,
            apiKey: { "ocm-key" },
            source: { .googlePlaces },
            googleApiKey: { "google-key" },
            session: makeSession()
        )

        let chargers = try await repo.chargersNearby(center: center)

        #expect(chargers.count == 1)
        #expect(chargers.first?.connectors.isEmpty == true)
        #expect(StubProtocol.requestCount == 4, "the 20 km x 20 km box should use Android's four 10 km tiles")
    }

    @Test("a successful refresh returns the new source's chargers")
    func successfulRefreshReturnsNewSourceRows() async throws {
        StubProtocol.requestCount = 0
        StubProtocol.responseBody = ocmResponse(id: 1, title: "Petronas Tapah")
        let context = ModelContext(makeContainer())

        let repo = ChargerRepository(
            modelContext: context,
            apiKey: { "ocm-key" },
            source: { .openChargeMap },
            session: makeSession()
        )

        let chargers = try await repo.chargersNear(center: center)

        #expect(chargers.map(\.id) == ["ocm-1"])
        #expect(chargers.first?.name == "Petronas Tapah")
        #expect(StubProtocol.requestCount == 1)
    }

    @Test("rows from another source are hidden once the current source has fresh data")
    func hidesOtherSources() async throws {
        StubProtocol.requestCount = 0
        let context = ModelContext(makeContainer())
        context.insert(entity(id: "ocm-1", name: "Petronas Tapah"))
        context.insert(entity(id: "apple-wxyz", name: "EV Charger"))
        try context.save()

        let repo = ChargerRepository(
            modelContext: context,
            apiKey: { "ocm-key" },
            source: { .openChargeMap },
            session: makeSession()
        )

        let chargers = try await repo.chargersNear(center: center)

        #expect(chargers.map(\.id) == ["ocm-1"], "Apple Maps leftovers must not mix into OCM results")
        #expect(StubProtocol.requestCount == 0, "fresh OCM rows should not trigger a refetch")
    }

    @Test("noteSourceChanged forces a refetch even when rows look fresh")
    func sourceChangeForcesRefresh() async throws {
        StubProtocol.requestCount = 0
        StubProtocol.responseBody = ocmResponse(id: 2, title: "Petronas Bidor")
        let context = ModelContext(makeContainer())
        context.insert(entity(id: "ocm-1", name: "Petronas Tapah"))
        try context.save()

        let repo = ChargerRepository(
            modelContext: context,
            apiKey: { "ocm-key" },
            source: { .openChargeMap },
            session: makeSession()
        )
        repo.noteSourceChanged()

        let chargers = try await repo.chargersNear(center: center)

        #expect(StubProtocol.requestCount == 1, "a source switch must re-fetch from the new provider")
        #expect(chargers.map(\.id).contains("ocm-2"))
    }
}
