import Foundation

/// Streams `TelemetrySample`s into a GPX 1.1 document the controlplane's
/// `GpsTrackParser` accepts. Speed goes in the Garmin TrackPointExtension
/// (`gpxtpx:speed`, m/s); g-forces ride in a `cv:gforce` extension element that
/// unknown parsers ignore.
///
/// Usage: `append(_:)` per sample (samples without a GPS fix are skipped),
/// then `finish()` for the trailing tags. Output is accumulated incrementally
/// so a multi-hour session never holds more than the encoded text.
public struct GPXWriter: Sendable {
    public static let creator = "CobbVision iOS"

    private var body = ""
    public private(set) var pointCount = 0
    private var finished = false
    private let trackName: String

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(trackName: String) {
        self.trackName = trackName
    }

    /// Appends one track point. Samples without a fix are dropped (returns false).
    @discardableResult
    public mutating func append(_ sample: TelemetrySample) -> Bool {
        precondition(!finished, "append after finish()")
        guard let lat = sample.latitude, let lon = sample.longitude else { return false }

        var point = "      <trkpt lat=\"\(format(lat))\" lon=\"\(format(lon))\">\n"
        if let alt = sample.altitudeM {
            point += "        <ele>\(format(alt))</ele>\n"
        }
        point += "        <time>\(Self.iso8601.string(from: sample.timestamp))</time>\n"

        let hasSpeed = sample.speedMps != nil
        let hasG = sample.gLateral != nil || sample.gLongitudinal != nil || sample.gVertical != nil
        if hasSpeed || hasG {
            point += "        <extensions>\n"
            if let speed = sample.speedMps {
                point += "          <gpxtpx:TrackPointExtension><gpxtpx:speed>\(format(speed))</gpxtpx:speed></gpxtpx:TrackPointExtension>\n"
            }
            if hasG {
                let lat = sample.gLateral.map(format) ?? ""
                let lon = sample.gLongitudinal.map(format) ?? ""
                let vert = sample.gVertical.map(format) ?? ""
                point += "          <cv:gforce lateral=\"\(lat)\" longitudinal=\"\(lon)\" vertical=\"\(vert)\"/>\n"
            }
            point += "        </extensions>\n"
        }
        point += "      </trkpt>\n"

        body += point
        pointCount += 1
        return true
    }

    /// Returns the complete GPX document. Idempotent once called.
    public mutating func finish() -> String {
        finished = true
        return Self.header(trackName: trackName) + body + Self.footer
    }

    private func format(_ value: Double) -> String {
        String(format: "%.7f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: ".0", options: .regularExpression)
    }

    private static func header(trackName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="\(creator)"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2"
             xmlns:cv="https://cobbvision.grio.co/xmlschemas/gforce/v1">
          <trk>
            <name>\(trackName.xmlEscaped)</name>
            <trkseg>\n
        """
    }

    private static let footer = """
        </trkseg>
      </trk>
    </gpx>
    """
}

extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
