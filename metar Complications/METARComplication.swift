import Foundation
import SwiftUI
import WidgetKit

private let refreshInterval: TimeInterval = 15 * 60

private enum AirportStore {
    struct Runway {
        let name: String
        let heading: Double
    }

    static let suiteName = "group.com.joshspicer.metar"
    static let airportKey = "selectedAirport"
    static let defaultAirport = "KPAE"
    static let runways: [String: [Runway]] = [
        "KPAE": [
            Runway(name: "16R", heading: 160), Runway(name: "34L", heading: 340),
            Runway(name: "16L", heading: 160), Runway(name: "34R", heading: 340),
            Runway(name: "11", heading: 110), Runway(name: "29", heading: 290)
        ],
        "KSEA": [
            Runway(name: "16L", heading: 160), Runway(name: "34R", heading: 340),
            Runway(name: "16C", heading: 160), Runway(name: "34C", heading: 340),
            Runway(name: "16R", heading: 160), Runway(name: "34L", heading: 340),
            Runway(name: "14L", heading: 140), Runway(name: "32R", heading: 320)
        ],
        "KBFI": [
            Runway(name: "14L", heading: 140), Runway(name: "32R", heading: 320),
            Runway(name: "14R", heading: 140), Runway(name: "32L", heading: 320)
        ]
    ]

    static var selectedAirport: String {
        UserDefaults(suiteName: suiteName)?.string(forKey: airportKey) ?? defaultAirport
    }
}

private struct WindAnalysis {
    let runway: String
    let crosswind: Double

    var crosswindText: String { String(format: "%.0f kt", crosswind) }
}

private struct METAR: Decodable {
    let observationTime: TimeInterval
    let temp: Double?
    let dewp: Double?
    let windDirection: Int?
    let windSpeed: Int?
    let visibility: String?
    let altimeter: Double?
    let flightCategory: String?

    enum CodingKeys: String, CodingKey {
        case observationTime = "obsTime"
        case temp
        case dewp
        case windDirection = "wdir"
        case windSpeed = "wspd"
        case visibility = "visib"
        case altimeter = "altim"
        case flightCategory = "fltCat"
    }

    var date: Date { Date(timeIntervalSince1970: observationTime) }
    var category: String { flightCategory ?? "--" }
    var wind: String {
        guard let windSpeed else { return "--" }
        guard windSpeed > 0 else { return "CALM" }
        let direction = windDirection.map { String(format: "%03d", $0) } ?? "---"
        return "\(direction)\u{00B0} \(windSpeed)KT"
    }
    var temperature: String { temp.map { String(format: "%.0f\u{00B0}", $0) } ?? "--" }
    var dewPoint: String { dewp.map { String(format: "%.0f\u{00B0}", $0) } ?? "--" }
    var visibilityText: String { visibility ?? "--" }
    var altimeterText: String { altimeter.map { String(format: "%.1f hPa", $0) } ?? "--" }

    var windAnalysis: WindAnalysis? {
        guard let windDirection, let windSpeed, windSpeed > 0,
              let runways = AirportStore.runways[AirportStore.selectedAirport] else { return nil }

        let bestRunway = runways.min {
            runwayDifference(from: windDirection, to: $0.heading) < runwayDifference(from: windDirection, to: $1.heading)
        }
        guard let bestRunway else { return nil }
        let difference = runwayDifference(from: windDirection, to: bestRunway.heading)
        let crosswind = abs(Double(windSpeed) * sin(difference * .pi / 180))
        return WindAnalysis(runway: bestRunway.name, crosswind: crosswind)
    }

    private func runwayDifference(from windDirection: Int, to runwayHeading: Double) -> Double {
        let difference = abs(Double(windDirection) - runwayHeading).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}

private struct METAREntry: TimelineEntry {
    let date: Date
    let report: METAR?
    let error: Bool
}

private struct METARProvider: TimelineProvider {
    func placeholder(in context: Context) -> METAREntry {
        METAREntry(date: .now, report: nil, error: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (METAREntry) -> Void) {
        completion(METAREntry(date: .now, report: nil, error: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<METAREntry>) -> Void) {
        Task {
            let report = try? await fetchReport()
            let entry = METAREntry(date: .now, report: report, error: report == nil)
            let nextUpdate = Date().addingTimeInterval(refreshInterval)
            completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
        }
    }

    private func fetchReport() async throws -> METAR {
        let airport = AirportStore.selectedAirport
        var components = URLComponents(string: "https://aviationweather.gov/api/data/metar")
        components?.queryItems = [
            URLQueryItem(name: "ids", value: airport),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw URLError(.badServerResponse)
        }
        guard let report = try JSONDecoder().decode([METAR].self, from: data).first else {
            throw URLError(.resourceUnavailable)
        }
        return report
    }
}

private struct METARComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: METAREntry

    var body: some View {
        if let report = entry.report {
            switch family {
            case .accessoryInline:
                Text("\(AirportStore.selectedAirport) XW \(report.windAnalysis?.crosswindText ?? "--") \(report.windAnalysis?.runway ?? "--")")
            case .accessoryCircular:
                Gauge(value: report.windAnalysis?.crosswind ?? 0, in: 0...60) {
                    Image(systemName: "wind")
                } currentValueLabel: {
                    Text(report.windAnalysis?.crosswindText ?? "--")
                        .font(.system(size: 9, weight: .semibold))
                }
                .gaugeStyle(.accessoryCircular)
            default:
                VStack(alignment: .leading, spacing: 2) {
                    Text(AirportStore.selectedAirport)
                        .font(.headline)
                    Text("\(report.category)  \(report.temperature) / \(report.dewPoint)")
                    Text("Wind \(report.wind)  Vis \(report.visibilityText)")
                        .font(.caption2)
                    Text("Alt \(report.altimeterText)")
                        .font(.caption2)
                    Text("Xwind \(report.windAnalysis?.crosswindText ?? "--")  RWY \(report.windAnalysis?.runway ?? "--")")
                        .font(.caption2)
                }
            }
        } else {
            Label("METAR unavailable", systemImage: "exclamationmark.triangle")
                .font(.caption2)
        }
    }
}

struct METARComplication: Widget {
    let kind = "METARComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: METARProvider()) { entry in
            METARComplicationView(entry: entry)
        }
        .configurationDisplayName("METAR WX")
        .description("Live aviation weather for the selected airport.")
        .supportedFamilies([
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

@main
struct METARComplicationBundle: WidgetBundle {
    var body: some Widget {
        METARComplication()
    }
}

#Preview("Inline", as: .accessoryInline) {
    METARComplication()
} timeline: {
    METAREntry(
        date: .now,
        report: METAR(
            observationTime: Date.now.timeIntervalSince1970,
            temp: 18,
            dewp: 12,
            windDirection: 210,
            windSpeed: 18,
            visibility: "10+",
            altimeter: 1016.7,
            flightCategory: "VFR"
        ),
        error: false
    )
}

#Preview("Circular", as: .accessoryCircular) {
    METARComplication()
} timeline: {
    METAREntry(
        date: .now,
        report: METAR(
            observationTime: Date.now.timeIntervalSince1970,
            temp: 18,
            dewp: 12,
            windDirection: 210,
            windSpeed: 18,
            visibility: "10+",
            altimeter: 1016.7,
            flightCategory: "VFR"
        ),
        error: false
    )
}

#Preview("Rectangular", as: .accessoryRectangular) {
    METARComplication()
} timeline: {
    METAREntry(
        date: .now,
        report: METAR(
            observationTime: Date.now.timeIntervalSince1970,
            temp: 18,
            dewp: 12,
            windDirection: 210,
            windSpeed: 18,
            visibility: "10+",
            altimeter: 1016.7,
            flightCategory: "VFR"
        ),
        error: false
    )
}
