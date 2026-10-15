import CoreLocation
import Observation
import SwiftUI
import UIKit
import UserNotifications

enum AppTab: Hashable {
    case day
    case history
    case export
    case settings
}

/// Opens the segment editor, possibly for several detected parts of one trip in a row.
struct EditorRequest: Identifiable {
    enum Origin: Equatable {
        case manual
        case edit
        case gap
        case suggestion
        case reminder(Reminder)
    }

    let id = UUID()
    var drafts: [SegmentDraft]
    var origin: Origin
}

enum ActiveSheet: Identifiable {
    case editor(EditorRequest)
    case datePicker

    var id: String {
        switch self {
        case .editor(let request): return "editor-\(request.id.uuidString)"
        case .datePicker: return "date-picker"
        }
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct PermissionsSnapshot: Equatable {
    var motion: MotionPermission = .notDetermined
    var notifications: UNAuthorizationStatus = .notDetermined
    var location: CLAuthorizationStatus = .notDetermined
}

/// The app's state and the glue between the UI, the on-device storage and the sensors.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private enum Keys {
        static let settings = "detectionSettings"
        static let dismissed = "dismissedSuggestions"
        static let onboarding = "hasCompletedOnboarding"
        static let reminderState = "reminderState"
    }

    // MARK: - Navigation

    var selectedTab: AppTab = .day
    var selectedDay: Date
    var sheet: ActiveSheet?
    var alert: AppAlert?
    private(set) var recentlyDeleted: Segment?

    // MARK: - Data

    private(set) var book = SegmentBook()
    private(set) var daysWithData: Set<Date> = []
    /// Increases with every change of the data, e.g. to refresh the export.
    private(set) var revision = 0
    /// False while the phone is locked after a restart and the data file cannot be read yet.
    private(set) var isDataLoaded = false

    // MARK: - Detection

    private(set) var currentActivity: ActivitySample?
    private(set) var detectedRuns: [Date: [DetectedRun]] = [:]
    private(set) var permissions = PermissionsSnapshot()
    private(set) var reminderState: ReminderState

    // MARK: - Stored preferences

    private var storedSettings: DetectionSettings
    private var dismissedSuggestions: Set<String>
    private var storedOnboardingDone: Bool

    // MARK: - Services

    let motion = MotionService()
    let notifications = NotificationService()
    let location = LocationWakeService()
    private let store: SegmentFileStore
    private let defaults: UserDefaults
    @ObservationIgnored private var isEvaluating = false
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
    @ObservationIgnored private var liveUpdatesRunning = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        store = SegmentFileStore(url: support
            .appendingPathComponent("SegmentValidator", isDirectory: true)
            .appendingPathComponent("segments.json"))
        storedSettings = Self.decode(DetectionSettings.self, from: defaults, key: Keys.settings) ?? DetectionSettings()
        reminderState = Self.decode(ReminderState.self, from: defaults, key: Keys.reminderState) ?? ReminderState()
        dismissedSuggestions = Set(defaults.stringArray(forKey: Keys.dismissed) ?? [])
        storedOnboardingDone = defaults.bool(forKey: Keys.onboarding)
        selectedDay = Calendar.current.startOfDay(for: .now)

        pruneDismissedSuggestions()
        loadSegments()

        location.onWake = { [weak self] in
            self?.handleLocationWake()
        }
        location.onAuthorizationChange = { [weak self] in
            self?.locationAuthorizationChanged()
        }
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loadSegmentsIfNeeded()
            }
        }
        #if DEBUG
        applyDebugLaunchOptions()
        #endif
    }

    // MARK: - Preferences

    var settings: DetectionSettings {
        get { storedSettings }
        set {
            let old = storedSettings
            storedSettings = newValue
            Self.encode(newValue, to: defaults, key: Keys.settings)
            if old.useLocationWakeUps != newValue.useLocationWakeUps || old.remindersEnabled != newValue.remindersEnabled {
                configureLocationWakeUps()
            }
            if old.sensitivity != newValue.sensitivity {
                detectedRuns = [:]
                Task { await refreshDetections(for: selectedDay) }
            }
        }
    }

    var hasCompletedOnboarding: Bool {
        get { storedOnboardingDone }
        set {
            storedOnboardingDone = newValue
            defaults.set(newValue, forKey: Keys.onboarding)
        }
    }

    // MARK: - Loading and saving

    private func loadSegments() {
        do {
            book = SegmentBook(segments: try store.load())
            isDataLoaded = true
        } catch is DecodingError {
            // The file exists but is damaged: keep a copy and start fresh instead of losing it silently.
            let copy = store.quarantineUnreadableFile()
            book = SegmentBook()
            isDataLoaded = true
            alert = AppAlert(
                title: String(localized: "Data could not be read"),
                message: L10n.format("The data file was damaged. A copy was kept as %@.", copy?.lastPathComponent ?? "-")
            )
        } catch {
            // Most likely the phone is still locked after a restart. Try again later, never overwrite.
            isDataLoaded = false
        }
        refreshDerivedData()
    }

    private func loadSegmentsIfNeeded() {
        if !isDataLoaded {
            loadSegments()
        }
    }

    private func commit(_ updated: SegmentBook) {
        loadSegmentsIfNeeded()
        guard isDataLoaded else {
            alert = AppAlert(
                title: String(localized: "Could not save"),
                message: String(localized: "Your data is not accessible right now. Unlock your iPhone and try again.")
            )
            return
        }
        book = updated
        refreshDerivedData()
        do {
            try store.save(updated.segments)
        } catch {
            alert = AppAlert(title: String(localized: "Could not save"), message: error.localizedDescription)
        }
    }

    private func refreshDerivedData() {
        daysWithData = book.daysWithSegments(calendar: .current, now: .now)
        revision += 1
    }

    // MARK: - Segments

    func timeline(for day: Date) -> DayTimeline {
        DayTimeline(day: day, book: book, calendar: .current, now: .now)
    }

    @discardableResult
    func save(_ draft: SegmentDraft) -> Bool {
        var updated = book
        do {
            try updated.save(draft, now: .now)
        } catch let error as DraftError {
            alert = AppAlert(title: String(localized: "Cannot save"), message: error.message)
            return false
        } catch {
            alert = AppAlert(title: String(localized: "Cannot save"), message: error.localizedDescription)
            return false
        }
        commit(updated)
        return true
    }

    func delete(_ segment: Segment) {
        deleteSegment(id: segment.id)
    }

    func deleteSegment(id: UUID) {
        var updated = book
        guard let removed = updated.delete(id: id) else { return }
        commit(updated)
        recentlyDeleted = removed
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.recentlyDeleted = nil
        }
    }

    func undoDelete() {
        guard let segment = recentlyDeleted else { return }
        var updated = book
        updated.insert(segment)
        commit(updated)
        recentlyDeleted = nil
        undoExpiry?.cancel()
    }

    func startLive(_ type: MovementType) {
        var updated = book
        updated.startLive(type, at: .now)
        commit(updated)
    }

    func stopLive() {
        var updated = book
        guard updated.stopLive(at: .now) != nil else { return }
        commit(updated)
    }

    func deleteAllData() {
        var empty = book
        empty.removeAll()
        commit(empty)
        resetDismissedSuggestions()
        reminderState = ReminderState()
        persistReminderState()
    }

    // MARK: - Editor

    func showEditor(_ drafts: [SegmentDraft], origin: EditorRequest.Origin) {
        guard !drafts.isEmpty else { return }
        sheet = .editor(EditorRequest(drafts: drafts, origin: origin))
    }

    func addSegment(on day: Date) {
        showEditor([DraftFactory.newDraft(on: day, book: book, now: .now, calendar: .current)], origin: .manual)
    }

    func addSegment(after segment: Segment) {
        showEditor([DraftFactory.draft(after: segment, book: book, now: .now)], origin: .manual)
    }

    func edit(_ segment: Segment) {
        showEditor([SegmentDraft(editing: segment)], origin: .edit)
    }

    func fill(_ gap: TimelineGap) {
        showEditor([DraftFactory.draft(for: gap)], origin: .gap)
    }

    func open(_ suggestion: Suggestion) {
        showEditor([DraftFactory.draft(for: suggestion)], origin: .suggestion)
    }

    /// The ✓ button: saves right away when the type is clear, otherwise asks for it.
    func accept(_ suggestion: Suggestion) {
        let draft = DraftFactory.draft(for: suggestion)
        guard draft.type != nil, book.validate(draft, now: .now).canSave else {
            open(suggestion)
            return
        }
        save(draft)
    }

    func dismiss(_ suggestion: Suggestion) {
        dismissedSuggestions.insert(suggestion.id)
        defaults.set(Array(dismissedSuggestions), forKey: Keys.dismissed)
    }

    var hasDismissedSuggestions: Bool {
        !dismissedSuggestions.isEmpty
    }

    func resetDismissedSuggestions() {
        dismissedSuggestions = []
        defaults.removeObject(forKey: Keys.dismissed)
    }

    /// Dismissed suggestions are keyed "activity@minute"; forget the ones older than two weeks.
    private func pruneDismissedSuggestions() {
        let cutoff = Int(Date().addingTimeInterval(-14 * 86_400).timeIntervalSince1970 / 60)
        let kept = dismissedSuggestions.filter { key in
            guard let minute = key.split(separator: "@").last.flatMap({ Int($0) }) else { return false }
            return minute >= cutoff
        }
        if kept != dismissedSuggestions {
            dismissedSuggestions = kept
            defaults.set(Array(kept), forKey: Keys.dismissed)
        }
    }

    func showDay(_ day: Date) {
        selectedDay = Calendar.current.startOfDay(for: day)
        selectedTab = .day
    }

    // MARK: - Detection

    func suggestions(for day: Date) -> [Suggestion] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let runs = detectedRuns[dayStart] else { return [] }
        return SuggestionBuilder.suggestions(
            runs: runs,
            book: book,
            within: calendar.dayInterval(containing: dayStart),
            dismissed: dismissedSuggestions,
            includeStationary: settings.suggestStationary,
            now: .now
        )
    }

    /// Reads the motion history of a day (iOS keeps the last seven days).
    func refreshDetections(for day: Date) async {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        #if DEBUG
        if defaults.bool(forKey: "debugFakeDetections") {
            detectedRuns[dayStart] = calendar.isDateInToday(dayStart) ? DemoData.detectedRuns(now: .now) : []
            return
        }
        #endif
        guard motion.permission == .authorized else {
            detectedRuns[dayStart] = nil
            return
        }
        let interval = calendar.dayInterval(containing: dayStart)
        let now = Date()
        guard interval.start < now else {
            detectedRuns[dayStart] = []
            return
        }
        let end = min(interval.end, now)
        do {
            let samples = try await motion.samples(from: interval.start.addingTimeInterval(-6 * 3600), to: end)
            detectedRuns[dayStart] = MovementDetector.runs(from: samples, until: end, parameters: settings.sensitivity.parameters)
        } catch {
            detectedRuns[dayStart] = []
        }
    }

    func motionHistoryAvailable(for day: Date) -> Bool {
        Calendar.current.dayInterval(containing: day).end > Date().addingTimeInterval(-7 * 86_400)
    }

    private func startLiveMotion() {
        guard motion.permission == .authorized, !liveUpdatesRunning else { return }
        liveUpdatesRunning = true
        motion.startLiveUpdates { [weak self] sample in
            guard let self else { return }
            let changed = self.currentActivity?.activity != sample.activity
            self.currentActivity = sample
            if changed {
                Task { await self.refreshDetections(for: .now) }
            }
        }
    }

    private func stopLiveMotion() {
        guard liveUpdatesRunning else { return }
        motion.stopLiveUpdates()
        liveUpdatesRunning = false
    }

    // MARK: - App lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            loadSegmentsIfNeeded()
            refreshPermissions()
            startLiveMotion()
            Task { await refreshDetections(for: selectedDay) }
        case .background:
            stopLiveMotion()
            BackgroundRefresh.schedule()
            BackgroundTime.run("movement-check") { [weak self] in
                await self?.evaluateReminders()
            }
        default:
            break
        }
    }

    func handleBackgroundRefresh() async {
        BackgroundRefresh.schedule()
        await evaluateReminders()
    }

    static func runBackgroundRefresh() async {
        await shared.handleBackgroundRefresh()
    }

    private func handleLocationWake() {
        BackgroundTime.run("location-wake") { [weak self] in
            await self?.evaluateReminders()
        }
    }

    // MARK: - Reminders

    /// Looks at the recent motion history and sends a reminder if a new movement needs logging.
    @discardableResult
    func evaluateReminders() async -> ReminderOutcome {
        guard !isEvaluating else { return .alreadyHandled }
        isEvaluating = true
        defer { isEvaluating = false }

        loadSegmentsIfNeeded()
        guard isDataLoaded else { return .alreadyHandled }
        guard settings.remindersEnabled else { return record(.disabled) }
        guard motion.permission == .authorized else { return record(.noPermission) }

        let now = Date()
        let samples: [ActivitySample]
        do {
            samples = try await motion.samples(from: now.addingTimeInterval(-(ReminderEngine.lookback + 3600)), to: now)
        } catch {
            return record(.noPermission)
        }
        let parameters = settings.sensitivity.parameters
        let runs = MovementDetector.runs(from: samples, until: now, parameters: parameters)
        let episodes = MovementDetector.episodes(from: runs, parameters: parameters)
        let result = ReminderEngine.evaluate(
            episodes: episodes,
            book: book,
            state: reminderState,
            settings: settings,
            now: now,
            calendar: .current
        )

        guard let reminder = result.reminder else {
            reminderState = result.state
            persistReminderState()
            return result.outcome
        }
        guard await notifications.canNotify() else {
            // Nothing could be shown, so nothing counts as reminded.
            return record(.noPermission)
        }
        await notifications.post(reminder, previous: book.previous(before: reminder.start))
        reminderState = result.state
        persistReminderState()
        return result.outcome
    }

    private func record(_ outcome: ReminderOutcome) -> ReminderOutcome {
        reminderState.lastCheckAt = .now
        reminderState.lastOutcome = outcome
        persistReminderState()
        return outcome
    }

    /// Called when the user taps a reminder or one of its buttons.
    func handleNotificationResponse(actionIdentifier: String, reminder: Reminder) async {
        if actionIdentifier == NotificationService.snoozeAction {
            await notifications.post(
                reminder,
                previous: book.previous(before: reminder.start),
                delay: NotificationService.snoozeDelay
            )
            return
        }
        guard actionIdentifier == NotificationService.logAction
            || actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

        showDay(reminder.start)
        let drafts = await drafts(for: reminder)
        if drafts.isEmpty {
            alert = AppAlert(
                title: String(localized: "Already logged"),
                message: String(localized: "This movement is already covered by your segments.")
            )
        } else {
            showEditor(drafts, origin: .reminder(reminder))
        }
    }

    /// One draft per detected part of the movement (e.g. walk, tram, walk), pre-filled with times.
    private func drafts(for reminder: Reminder) async -> [SegmentDraft] {
        let now = Date()
        let end = max(reminder.end ?? now, reminder.start.addingTimeInterval(60))
        let bounds = DateInterval(start: reminder.start.flooredToMinute, end: end)
        let logged = IntervalMath.unionDuration(of: book.segments.map { $0.interval(now: now) }, within: bounds)
        if logged >= bounds.duration * 0.9 {
            return []
        }
        if motion.permission == .authorized,
           let samples = try? await motion.samples(from: reminder.start.addingTimeInterval(-3600), to: max(end, now)) {
            let runs = MovementDetector.runs(from: samples, until: now, parameters: settings.sensitivity.parameters)
            let parts = SuggestionBuilder.suggestions(
                runs: runs,
                book: book,
                within: bounds,
                dismissed: [],
                includeStationary: false,
                now: now
            )
            if !parts.isEmpty {
                return parts.map { DraftFactory.draft(for: $0) }
            }
        }
        return [DraftFactory.draft(for: reminder, now: now)]
    }

    func sendTestReminder() async {
        let start = Date().addingTimeInterval(-12 * 60).flooredToMinute
        let reminder = Reminder(start: start, end: nil, activity: .walking)
        await notifications.post(reminder, previous: book.previous(before: start), delay: 5, identifier: "test-reminder")
    }

    // MARK: - Permissions

    func refreshPermissions() {
        Task {
            let notificationStatus = await notifications.authorizationStatus()
            permissions = PermissionsSnapshot(
                motion: motion.permission,
                notifications: notificationStatus,
                location: location.authorizationStatus
            )
        }
    }

    func requestMotionPermission() async {
        _ = await motion.requestAuthorization()
        refreshPermissions()
        startLiveMotion()
        await refreshDetections(for: selectedDay)
    }

    func requestNotificationPermission() async {
        _ = await notifications.requestAuthorization()
        refreshPermissions()
    }

    /// Starts or stops the optional location based wake-ups. Called on every launch.
    func configureLocationWakeUps() {
        let wanted = settings.useLocationWakeUps && settings.remindersEnabled
        if wanted {
            switch location.authorizationStatus {
            case .notDetermined, .authorizedWhenInUse:
                // iOS shows the "Always" prompt at most once; later calls are ignored.
                location.requestAlwaysAuthorization()
            default:
                break
            }
        }
        location.setMonitoring(wanted)
    }

    private func locationAuthorizationChanged() {
        refreshPermissions()
        location.setMonitoring(settings.useLocationWakeUps && settings.remindersEnabled)
    }

    // MARK: - Export and import

    /// Writes the CSV to a temporary file for the share sheet.
    func exportFile(options: CSVOptions, range: ClosedRange<Date>?) throws -> URL {
        let calendar = Calendar.current
        var segments = book.segments
        if let range {
            let from = calendar.startOfDay(for: range.lowerBound)
            let until = calendar.dayInterval(containing: range.upperBound).end
            segments = segments.filter { $0.start >= from && $0.start < until }
        }
        let data = CSVExport.data(for: segments, options: options, timeZone: .current)
        let name = CSVExport.fileName(first: segments.first?.start, last: segments.last?.start, timeZone: .current)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Imports a CSV file (e.g. a backup) and returns a summary for the user.
    func importCSV(from url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return String(localized: "The file is not a text file.")
            }
            let result = try CSVImport.segments(fromCSV: text, timeZone: .current)
            var updated = book
            let merge = updated.merge(result.segments)
            commit(updated)
            var message = L10n.format("%1$lld added, %2$lld updated, %3$lld already known.", merge.added, merge.updated, merge.unchanged)
            if !result.skippedLines.isEmpty {
                let lines = result.skippedLines.map { String($0) }.joined(separator: ", ")
                message += "\n" + L10n.format("Skipped lines: %@", lines)
            }
            return message
        } catch CSVImport.ImportError.missingColumns {
            return String(localized: "The file needs the columns movement_type and start_iso (or date and start_time).")
        } catch CSVImport.ImportError.empty {
            return String(localized: "The file is empty.")
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Overviews

    func totals(in interval: DateInterval) -> [TypeTotal] {
        book.totalsByType(within: interval, now: .now)
    }

    func typesByDay(in interval: DateInterval) -> [Date: [MovementType]] {
        book.typesByDay(within: interval, calendar: .current, now: .now)
    }

    // MARK: - Debug launch options

    #if DEBUG
    /// See DemoData for the supported launch arguments.
    private func applyDebugLaunchOptions() {
        if defaults.bool(forKey: "debugSeedDemoData"), isDataLoaded, book.segments.isEmpty {
            commit(SegmentBook(segments: DemoData.segments(now: .now, calendar: .current)))
        }
        if defaults.bool(forKey: "debugShowYesterday") {
            selectedDay = Calendar.current.date(byAdding: .day, value: -1, to: selectedDay) ?? selectedDay
        }
        switch defaults.string(forKey: "debugInitialTab") {
        case "history": selectedTab = .history
        case "export": selectedTab = .export
        case "settings": selectedTab = .settings
        default: break
        }
        switch defaults.string(forKey: "debugOpenEditor") {
        case "reminder":
            let reminder = DemoData.reminder(now: .now)
            showEditor([DraftFactory.draft(for: reminder, now: .now)], origin: .reminder(reminder))
        case "new":
            addSegment(on: selectedDay)
        default:
            break
        }
    }
    #endif

    // MARK: - UserDefaults helpers

    private func persistReminderState() {
        Self.encode(reminderState, to: defaults, key: Keys.reminderState)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
