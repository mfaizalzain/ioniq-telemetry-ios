import Foundation

/// Minimal geohash encoder for the charger cache index (precision 6 ≈ 1.2 km cells).
public enum Geohash {
    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    public static func encode(lat: Double, lon: Double, precision: Int = 6) -> String {
        var latLo = -90.0, latHi = 90.0
        var lonLo = -180.0, lonHi = 180.0
        var result = ""
        var isEven = true
        var bit = 0
        var ch = 0

        while result.count < precision {
            if isEven {
                let mid = (lonLo + lonHi) / 2
                if lon >= mid { ch = (ch << 1) | 1; lonLo = mid } else { ch = ch << 1; lonHi = mid }
            } else {
                let mid = (latLo + latHi) / 2
                if lat >= mid { ch = (ch << 1) | 1; latLo = mid } else { ch = ch << 1; latHi = mid }
            }
            isEven = !isEven
            bit += 1
            if bit == 5 {
                result.append(base32[ch])
                bit = 0; ch = 0
            }
        }
        return result
    }

    /// Geohash prefixes covering a bounding box, for prefix-indexed cache queries.
    public static func coveringPrefixes(
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double, precision: Int = 4
    ) -> Set<String> {
        var out = Set<String>()
        let latStepActual = max(maxLat - minLat, 0.01) / 8
        let lonStepActual = max(maxLon - minLon, 0.01) / 8

        var lat = minLat
        while lat <= maxLat {
            var lon = minLon
            while lon <= maxLon {
                out.insert(encode(lat: lat, lon: lon, precision: precision))
                lon += lonStepActual
            }
            lat += latStepActual
        }
        return out
    }
}
