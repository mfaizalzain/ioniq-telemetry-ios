import CoreDomain
import Foundation
import Testing
@testable import CoreData

/// Exercises the real request → decode path of `OccupancyRepository` against a
/// stubbed URLProtocol: if this passes, the Places call is well-formed and the
/// live-status pipeline works — any "no status shown" is then a matching or
/// data-availability problem, not a broken request.
@Suite("OccupancyRepository", .serialized)
struct OccupancyRepositoryTests {

    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var capturedRequest: URLRequest?
        nonisolated(unsafe) static var responseBody = Data("{}".utf8)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.capturedRequest = request
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

    @Test("requests id, name, location and availability, and decodes them")
    func decodesStatusedStations() async throws {
        StubProtocol.responseBody = Data("""
        {
          "places": [
            {
              "id": "places/ChIJabc",
              "displayName": { "text": "Shell Recharge Tapah" },
              "location": { "latitude": 4.201, "longitude": 101.101 },
              "evChargeOptions": {
                "connectorCount": 2,
                "connectorAggregation": [
                  { "availableCount": 1, "count": 2 }
                ]
              }
            }
          ]
        }
        """.utf8)

        let repo = OccupancyRepository(session: makeSession())
        let snapshot = try await repo.occupancyNear(
            LatLon(lat: 4.2, lon: 101.1), radiusM: 25_000, apiKey: "key"
        )

        #expect(snapshot.stations.count == 1)
        let station = snapshot.stations[0]
        #expect(station.name == "Shell Recharge Tapah")
        #expect(station.availableCount == 1)
        #expect(station.totalCount == 2)
        #expect(station.placeId == "places/ChIJabc")
        #expect(station.lat == 4.201)
        #expect(station.lon == 101.101)
    }

    @Test("uses connector aggregation totals when connectorCount is omitted")
    func decodesAggregatedConnectorTotal() async throws {
        StubProtocol.responseBody = Data("""
        {
          "places": [
            {
              "id": "places/ChIJaggregate",
              "displayName": { "text": "Aggregated Charger" },
              "location": { "latitude": 4.201, "longitude": 101.101 },
              "evChargeOptions": {
                "connectorAggregation": [
                  { "availableCount": 1, "count": 2 },
                  { "availableCount": 2, "count": 4 }
                ]
              }
            }
          ]
        }
        """.utf8)

        let snapshot = try await OccupancyRepository(session: makeSession()).occupancyNear(
            LatLon(lat: 4.2, lon: 101.1), radiusM: 10_000, apiKey: "key"
        )

        #expect(snapshot.stations.first?.availableCount == 3)
        #expect(snapshot.stations.first?.totalCount == 6)
    }

    @Test("partial connector availability does not count unknown groups as full")
    func decodesOnlyReportedConnectorGroups() async throws {
        StubProtocol.responseBody = Data("""
        {
          "places": [
            {
              "displayName": { "text": "Partial Status" },
              "evChargeOptions": {
                "connectorCount": 6,
                "connectorAggregation": [
                  { "availableCount": 0, "count": 2 },
                  { "count": 4 }
                ]
              }
            }
          ]
        }
        """.utf8)

        let snapshot = try await OccupancyRepository(session: makeSession()).occupancyNear(
            LatLon(lat: 4.2, lon: 101.1), radiusM: 10_000, apiKey: "key"
        )

        #expect(snapshot.stations.first?.availableCount == 0)
        #expect(snapshot.stations.first?.totalCount == 2)
    }

    @Test("field mask carries id and location so matching can be exact")
    func fieldMaskIncludesIdentityAndLocation() async throws {
        StubProtocol.responseBody = Data("{}".utf8)
        StubProtocol.capturedRequest = nil
        _ = try? await OccupancyRepository(session: makeSession()).occupancyNear(
            LatLon(lat: 4.2, lon: 101.1), radiusM: 25_000, apiKey: "key"
        )

        let request = StubProtocol.capturedRequest
        #expect(request?.value(forHTTPHeaderField: "X-Goog-Api-Key") == "key")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let mask = request?.value(forHTTPHeaderField: "X-Goog-FieldMask") ?? ""
        #expect(mask.contains("places.id"))
        #expect(mask.contains("places.location"))
        #expect(mask.contains("places.evChargeOptions"))
    }
}
