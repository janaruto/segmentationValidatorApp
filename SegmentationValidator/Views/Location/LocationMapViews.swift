import MapKit
import SwiftUI

/// A stretch of the day's route with one logged movement type, drawn in that type's color.
struct RouteTrack: Identifiable {
    let id: Int
    var coordinates: [CLLocationCoordinate2D]
    var color: Color
}

enum Route {
    /// Splits the points into tracks by the segment logged at each point's time.
    static func tracks(for points: [LocationPoint], book: SegmentBook, now: Date) -> [RouteTrack] {
        var tracks: [RouteTrack] = []
        var current: [CLLocationCoordinate2D] = []
        var currentType: MovementType?
        for point in points {
            let type = book.segment(at: point.timestamp, now: now)?.type
            if !current.isEmpty && type != currentType {
                // End the track at this point, so the line has no hole.
                current.append(point.coordinate)
                tracks.append(RouteTrack(id: tracks.count, coordinates: current, color: color(for: currentType)))
                current = []
            }
            current.append(point.coordinate)
            currentType = type
        }
        if current.count > 1 {
            tracks.append(RouteTrack(id: tracks.count, coordinates: current, color: color(for: currentType)))
        }
        return tracks
    }

    /// Points outside any segment are drawn in the app's color.
    static func color(for type: MovementType?) -> Color {
        type?.color ?? Color.brand
    }

    /// "37 points · 24 km"
    static func summary(points: [LocationPoint]) -> String {
        let distance = GeoMath.travelledDistance(along: points.filter(\.isAccurate))
        return L10n.format("%1$lld points · %2$@", points.count, Formatting.distance(distance))
    }
}

/// The location points of the shown day on the day screen. Tap to open the map.
struct LocationDaySection: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let points = model.points(on: day)
        let accurate = points.filter(\.isAccurate)
        let isToday = Calendar.current.isDateInToday(day)
        if !points.isEmpty || (isToday && model.settings.locationTracking) {
            Section {
                if accurate.isEmpty {
                    Label(
                        points.isEmpty ? "No location points yet. The first one follows within a few minutes." : "No accurate location points yet.",
                        systemImage: "location"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        model.sheet = .locationMap(day)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            RouteMapPreview(points: accurate, tracks: Route.tracks(for: accurate, book: model.book, now: .now))
                                .frame(height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .id(accurate.count)
                            HStack(spacing: 6) {
                                Text(Route.summary(points: points))
                                Spacer(minLength: 8)
                                if let last = points.last {
                                    Text(L10n.format("Last %@", Formatting.time(last.timestamp)))
                                        .monospacedDigit()
                                }
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the map")
                }
            } header: {
                Text("Location points")
            }
        }
    }
}

/// The route on a small map without interaction.
struct RouteMapPreview: View {
    let points: [LocationPoint]
    let tracks: [RouteTrack]

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: []) {
            ForEach(tracks) { track in
                MapPolyline(coordinates: track.coordinates)
                    .stroke(track.color, lineWidth: 4)
            }
            ForEach(points.suffix(1)) { point in
                Annotation(Formatting.time(point.timestamp), coordinate: point.coordinate) {
                    PointDot(color: Color.brand, isSelected: true)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// All location points of a day on a map, colored by the movement type logged at that time.
struct LocationMapSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let day: Date

    @State private var selection: UUID?

    var body: some View {
        let points = model.points(on: day).filter(\.isAccurate)
        let tracks = Route.tracks(for: points, book: model.book, now: .now)

        NavigationStack {
            Map(initialPosition: .automatic, selection: $selection) {
                ForEach(tracks) { track in
                    MapPolyline(coordinates: track.coordinates)
                        .stroke(track.color, lineWidth: 5)
                }
                ForEach(points) { point in
                    Annotation(Formatting.time(point.timestamp), coordinate: point.coordinate) {
                        PointDot(
                            color: Route.color(for: model.book.segment(at: point.timestamp, now: .now)?.type),
                            isSelected: selection == point.id,
                            isQuestion: point.prompt != nil
                        )
                    }
                    .annotationTitles(.hidden)
                    .tag(point.id)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .bottom) {
                infoPanel(points: points)
            }
            .navigationTitle(Formatting.dayTitle(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func infoPanel(points: [LocationPoint]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let index = points.firstIndex(where: { $0.id == selection }) {
                PointDetails(point: points[index], previous: index > 0 ? points[index - 1] : nil)
            } else if points.isEmpty {
                Text("No location points on this day.")
                    .font(.subheadline)
            } else {
                Text(Route.summary(points: points))
                    .font(.headline)
                Text("Tap a point for its time and accuracy. The colors show the logged segments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// Time, accuracy, segment and question of one location point.
private struct PointDetails: View {
    @Environment(AppModel.self) private var model
    let point: LocationPoint
    let previous: LocationPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(Formatting.timeWithSeconds(point.timestamp)) · ±\(Formatting.distance(point.accuracy))")
                .font(.headline.monospacedDigit())
            if let segment = model.book.segment(at: point.timestamp, now: .now) {
                Label(segment.type.displayName, systemImage: segment.type.symbolName)
                    .font(.subheadline)
                    .foregroundStyle(segment.type.color)
            } else {
                Text("No segment logged at this time")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let previous {
                Text(L10n.format("%@ from the previous point", Formatting.distance(previous.distance(to: point))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let kind = point.prompt {
                Text(verbatim: "\(kind.title): \(answerText)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brand)
            }
        }
    }

    private var answerText: String {
        switch point.answer {
        case .some(true): return String(localized: "True")
        case .some(false): return String(localized: "False")
        case .none: return String(localized: "Not answered")
        }
    }
}

/// A location point on the map.
struct PointDot: View {
    let color: Color
    var isSelected = false
    var isQuestion = false

    var body: some View {
        let size: CGFloat = isSelected ? 16 : (isQuestion ? 12 : 9)
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white, lineWidth: isSelected ? 3 : 1.5))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}
