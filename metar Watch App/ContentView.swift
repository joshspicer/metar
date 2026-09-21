//
//  ContentView.swift
//  metar Watch App
//
//  Created by Josh Spicer on 9/20/26.
//

import Foundation
import Combine
import SwiftUI
import WidgetKit

private enum AirportStore {
    static let suiteName = "group.com.joshspicer.metar"
    static let airportKey = "selectedAirport"
    static let lastFetchedKey = "lastFetched"
    static let airports = ["KPAE", "KSEA", "KBFI"]
    struct Runway {
        let name: String
        let heading: Double
    }

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

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static var selectedAirport: String {
        get { defaults.string(forKey: airportKey) ?? airports[0] }
        set { defaults.set(newValue, forKey: airportKey) }
    }

    static var lastFetched: Date? {
        get {
            guard let timestamp = defaults.object(forKey: lastFetchedKey) as? Double else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        }
        set { defaults.set(newValue?.timeIntervalSince1970, forKey: lastFetchedKey) }
    }
}

private struct METAR: Decodable {
    let icaoID: String
    let obsTime: TimeInterval
    let temp: Double?
    let dewp: Double?
    let windDirection: Int?
    let windSpeed: Int?
    let visibility: String?
    let altimeter: Double?
    let rawObservation: String
    let flightCategory: String?

    enum CodingKeys: String, CodingKey {
        case icaoID = "icaoId"
        case obsTime
        case temp
        case dewp
        case windDirection = "wdir"
        case windSpeed = "wspd"
        case visibility = "visib"
        case altimeter = "altim"
        case rawObservation = "rawOb"
        case flightCategory = "fltCat"
    }
}

private struct WindAnalysis {
    let runway: String
    let crosswind: Double

    var crosswindText: String { String(format: "%.0f kt", crosswind) }
}

@MainActor
private final class METARViewModel: ObservableObject {
    @Published private(set) var selectedAirport = AirportStore.selectedAirport
    @Published private(set) var report: METAR?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastFetched = AirportStore.lastFetched

    private var refreshTask: Task<Void, Never>?

    deinit {
        refreshTask?.cancel()
    }

    func startAutomaticRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func stopAutomaticRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func selectAirport(_ airport: String) {
        guard AirportStore.airports.contains(airport), airport != selectedAirport else { return }
        AirportStore.selectedAirport = airport
        selectedAirport = airport
        report = nil
        lastFetched = nil
        AirportStore.lastFetched = nil
        Task { await load() }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var components = URLComponents(string: "https://aviationweather.gov/api/data/metar")
            components?.queryItems = [
                URLQueryItem(name: "ids", value: selectedAirport),
                URLQueryItem(name: "format", value: "json")
            ]

            guard let url = components?.url else {
                throw URLError(.badURL)
            }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  200..<300 ~= httpResponse.statusCode else {
                throw URLError(.badServerResponse)
            }

            let reports = try JSONDecoder().decode([METAR].self, from: data)
            guard let report = reports.first else {
                throw NSError(domain: "METAR", code: 1, userInfo: [NSLocalizedDescriptionKey: "No report available"])
            }
            self.report = report
            lastFetched = Date()
            AirportStore.lastFetched = lastFetched
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = METARViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(viewModel.selectedAirport)
                        .font(.headline)
                    Spacer()
                    Picker("Airport", selection: Binding(
                        get: { viewModel.selectedAirport },
                        set: { viewModel.selectAirport($0) }
                    )) {
                        ForEach(AirportStore.airports, id: \.self) { airport in
                            Text(airport).tag(airport)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityLabel("Choose airport")
                    Button {
                        Task { await viewModel.load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isLoading)
                }

                if viewModel.isLoading && viewModel.report == nil {
                    ProgressView("Loading")
                } else if let report = viewModel.report {
                    reportView(report)
                } else if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    Text("No report loaded")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .task {
            viewModel.startAutomaticRefresh()
        }
        .onDisappear {
            viewModel.stopAutomaticRefresh()
        }
    }

    @ViewBuilder
    private func reportView(_ report: METAR) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(report.flightCategory ?? "Unknown", systemImage: "cloud.sun.fill")
                    .foregroundStyle(report.flightCategoryColor)
                Spacer()
                Text(report.observationDate, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let lastFetched = viewModel.lastFetched {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Image(systemName: "clock.fill")
                        .font(.caption2)
                    .foregroundStyle(lastFetched.fetchAgeColor(at: context.date))
                        .accessibilityLabel("METAR data freshness")
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    Text("Wind")
                    Text(report.windDescription)
                }
                GridRow {
                    Text("Visibility")
                    Text(report.visibility ?? "--")
                }
                GridRow {
                    Text("Temp / Dew")
                    Text("\(report.tempText) / \(report.dewPointText) C")
                }
                GridRow {
                    Text("Altimeter")
                    Text(report.altimeterText)
                }
                GridRow {
                    Text("Crosswind")
                    Text(report.windAnalysis?.crosswindText ?? "--")
                }
                GridRow {
                    Text("Best runway")
                    Text(report.windAnalysis?.runway ?? "--")
                }
            }
            .font(.caption)

            Text(report.rawObservation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension METAR {
    var observationDate: Date { Date(timeIntervalSince1970: obsTime) }

    var windDescription: String {
        guard let windSpeed else { return "--" }
        if windSpeed == 0 { return "Calm" }
        let direction = windDirection.map { String(format: "%03d", $0) } ?? "---"
        return "\(direction) at \(windSpeed) kt"
    }

    var tempText: String { temp.map { String(format: "%.0f", $0) } ?? "--" }
    var dewPointText: String { dewp.map { String(format: "%.0f", $0) } ?? "--" }
    var altimeterText: String { altimeter.map { String(format: "%.1f hPa", $0) } ?? "--" }

    var windAnalysis: WindAnalysis? {
        guard let windDirection, let windSpeed, windSpeed > 0,
              let runways = AirportStore.runways[icaoID] else { return nil }

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

    var flightCategoryColor: Color {
        switch flightCategory {
        case "VFR": .green
        case "MVFR": .blue
        case "IFR": .red
        case "LIFR": .purple
        default: .secondary
        }
    }
}

private extension Date {
    func fetchAgeColor(at now: Date) -> Color {
        let age = now.timeIntervalSince(self)
        if age > 60 * 60 { return .red }
        if age > 45 * 60 { return .orange }
        return .secondary
    }
}

#Preview {
    ContentView()
}
