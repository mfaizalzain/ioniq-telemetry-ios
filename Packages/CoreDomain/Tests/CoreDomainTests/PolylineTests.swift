import Testing
@testable import CoreDomain

/// The 3D case is the one that matters: OpenRouteService returns a third delta per
/// point when elevation is requested, and failing to consume it scrambles every
/// coordinate after the first.
struct PolylineTests {

    @Test("decodes the canonical Google example")
    func decodesGoogleExample() {
        // From Google's encoded-polyline documentation.
        let points = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", is3D: false)
        #expect(points.count == 3)
        #expect(abs(points[0].lat - 38.5) < 0.00001)
        #expect(abs(points[0].lon - (-120.2)) < 0.00001)
        #expect(abs(points[1].lat - 40.7) < 0.00001)
        #expect(abs(points[1].lon - (-120.95)) < 0.00001)
        #expect(abs(points[2].lat - 43.252) < 0.00001)
        #expect(abs(points[2].lon - (-126.453)) < 0.00001)
    }

    @Test("a 3D polyline decodes to the same coordinates as its 2D twin")
    func threeDimensionalSkipsElevation() {
        // Same two points, with a zero elevation delta ("?") interleaved.
        let flat = Polyline.decode("_p~iF~ps|U_ulLnnqC", is3D: false)
        let withElevation = Polyline.decode("_p~iF~ps|U?_ulLnnqC?", is3D: true)

        #expect(flat.count == 2)
        #expect(withElevation.count == 2)
        for (a, b) in zip(flat, withElevation) {
            #expect(abs(a.lat - b.lat) < 0.00001)
            #expect(abs(a.lon - b.lon) < 0.00001)
        }
    }

    @Test("reading a 3D polyline as 2D produces different, wrong coordinates")
    func misreadingDimensionsCorrupts() {
        let correct = Polyline.decode("_p~iF~ps|U?_ulLnnqC?", is3D: true)
        let misread = Polyline.decode("_p~iF~ps|U?_ulLnnqC?", is3D: false)
        #expect(correct.count == 2)
        #expect(correct != misread)
    }

    @Test("empty and malformed input yield no points rather than spinning")
    func handlesBadInput() {
        #expect(Polyline.decode("", is3D: false).isEmpty)
        #expect(Polyline.decode("_", is3D: false).isEmpty)
    }
}
