import Foundation

/// Serialises a DriveSession to a GPX 1.1 string.
/// The speed extension uses the Garmin TrackPointExtension v2 schema so
/// it's understood by common tools (GoldenCheetah, Strava, etc.).
struct GPXExporter {

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func gpxString(for session: DriveSession) -> String {
        let name    = "CobbVision \(formattedDate(session.startedAt))"
        let created = iso8601.string(from: session.startedAt)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"
             creator="CobbVision Companion/1.0"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <metadata>
            <name>\(xmlEscape(name))</name>
            <time>\(created)</time>
          </metadata>
          <trk>
            <name>\(xmlEscape(name))</name>
            <trkseg>\n
        """

        for pt in session.trackPoints {
            let time  = iso8601.string(from: pt.timestamp)
            let speed = String(format: "%.4f", max(0, pt.speedMS))
            xml += """
                  <trkpt lat="\(pt.latitude)" lon="\(pt.longitude)">
                    <ele>\(String(format: "%.2f", pt.altitude))</ele>
                    <time>\(time)</time>
                    <extensions>
                      <gpxtpx:TrackPointExtension>
                        <gpxtpx:speed>\(speed)</gpxtpx:speed>
                      </gpxtpx:TrackPointExtension>
                    </extensions>
                  </trkpt>\n
            """
        }

        xml += """
            </trkseg>
          </trk>
        </gpx>
        """
        return xml
    }

    /// Write GPX to a temporary file and return the URL.
    static func export(session: DriveSession) throws -> URL {
        let gpx      = gpxString(for: session)
        let fileName = "cobbvision_\(Int(session.startedAt.timeIntervalSince1970)).gpx"
        let url      = FileManager.default
                           .temporaryDirectory
                           .appendingPathComponent(fileName)
        try gpx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    private static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
