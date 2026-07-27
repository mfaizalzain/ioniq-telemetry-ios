import CoreDomain
import Foundation

/// Google-style encoded polyline decoder.
///
/// OpenRouteService returns a 3D polyline when elevation is requested — a third
/// delta per point that must be consumed and discarded, or every coordinate after
/// the first comes out scrambled. Google's overview polylines are 2D.
public enum Polyline {

    public static func decode(_ encoded: String, is3D: Bool) -> [LatLon] {
        var points: [LatLon] = []
        var index = encoded.startIndex
        var lat = 0, lon = 0

        func nextValue() -> Int? {
            var result = 0
            var shift = 0
            var sawTerminator = false
            while index < encoded.endIndex {
                guard let ascii = encoded[index].asciiValue else { return nil }
                index = encoded.index(after: index)
                let chunk = Int(ascii) - 63
                result |= (chunk & 0x1F) << shift
                shift += 5
                if chunk < 0x20 { sawTerminator = true; break }
                if shift > 30 { return nil }        // malformed: bail rather than spin
            }
            guard sawTerminator else { return nil }
            // Zig-zag: the low bit carries the sign.
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while index < encoded.endIndex {
            guard let dLat = nextValue(), let dLon = nextValue() else { break }
            lat += dLat
            lon += dLon
            if is3D, nextValue() == nil { break }   // elevation delta: consumed, unused
            points.append(LatLon(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5))
        }
        return points
    }
}
