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
        case staleSegment(StaleSegmentReminder)
    }

    let id = UUID()
    var drafts: [SegmentDraft]
    var origin: Origin
}

/// "True" on "Moving detected?": the sheet that asks how the user is moving.
struct MovingAnswer: Identifiable {
    var prompt: LocationPrompt
    /// Estimated start of the movement.
    var start: Date
    /// What the motion sensor detected, if anything.
    var activity: DetectedActivity?

    var id: UUID { prompt.id }
}

enum ActiveSheet: Identifiable {
    case editor(EditorRequest)
    case datePicker
    case movingAnswer(MovingAnswer)
    case locationMap(Date)

    var id: String {
        switch self {
        case .editor(let request): return "editor-\(request.id.uuidString)"
        case .datePicker: return "date-picker"
        case .movingAnswer(let answer): return "moving-\(answer.id.uuidString)"
        case .locationMap(let day): return "map-\(Int(day.timeIntervalSince1970))"
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
    /// False when only the approximate location is allowed.
    var preciseLocation = true
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
        static let locationState = "locationState"
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

    // MARK: - Location points

    /// What the location questions remember between points.
    private(set) var locationState: LocationPromptState
    /// Increases whenever location points change, e.g. to refresh the map and the export.
    private(set) var locationRevision = 0
    @ObservationIgnored private var pointsCache: [Date: [LocationPoint]] = [:]
    /// Points that could not be written yet (e.g. while the phone is locked after a restart).
    @ObservationIgnored private var unsavedPoints: [LocationPoint] = []

    // MARK: - Stored preferences

    private var storedSettings: DetectionSettings
    private var dismissedSuggestions: Set<String>
    private var storedOnboardingDone: Bool

    // MARK: - Services

    let motion = MotionService()
    let notifications = NotificationService()
    let location = LocationWakeService()
    let tracker = LocationTracker()
    private let store: SegmentFileStore
    private let pointStore: LocationPointStore
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
        let folder = support.appendingPathComponent("SegmentValidator", isDirectory: true)
        store = SegmentFileStore(url: folder.appendingPathComponent("segments.json"))
        pointStore = LocationPointStore(folder: folder.appendingPathComponent("Locations", isDirectory: true))
        storedSettings = Self.decode(DetectionSettings.self, from: defaults, key: Keys.settings) ?? DetectionSettings()
        reminderState = Self.decode(ReminderState.self, from: defaults, key: Keys.reminderState) ?? ReminderState()
        locationState = Self.decode(LocationPromptState.self, from: defaults, key: Keys.locationState) ?? LocationPromptState()
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
        tracker.onFix = { [weak self] fix in
            self?.recordPoint(fix)
        }
        tracker.onAuthorizationChange = { [weak self] in
            self?.locationAuthorizationChanged()
        }
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loadSegmentsIfNeeded()
                self?.flushPoints()
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
            if old.useLocationWakeUps != newValue.useLocationWakeUps
                || old.remindersEnabled != newValue.remindersEnabled
                || old.locationTracking != newValue.locationTracking
                || old.locationInterval != newValue.locationInterval {
                configureLocation()
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

    /// Applies and stores a change. Returns false if nothing was saved.
    @discardableResult
    private func commit(_ updated: SegmentBook) -> Bool {
        guard isDataLoaded else {
            // The change was made on data that was not loaded yet: never write it over the real file.
            loadSegmentsIfNeeded()
            alert = AppAlert(
                title: String(localized: "Could not save"),
                message: String(localized: "Your data is not accessible right now. Unlock your iPhone and try again.")
            )
            return false
        }
        book = updated
        refreshDerivedData()
        do {
            try store.save(updated.segments)
            return true
        } catch {
            alert = AppAlert(title: String(localized: "Could not save"), message: error.localizedDescription)
            return false
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
        return commit(updated)
    }

    func delete(_ segment: Segment) {
        deleteSegment(id: segment.id)
    }

    func deleteSegment(id: UUID) {
        var updated = book
        guard let removed = updated.delete(id: id), commit(updated) else { return }
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
        guard commit(updated) else { return }
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
        deleteLocationPoints()
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
            flushPoints()
            refreshPermissions()
            startLiveMotion()
            tracker.measureIfDue(.appOpened)
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
        tracker.measureIfDue(.wakeUp)
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
        // While location points are recorded, "Moving detected?" and "Stationary?" take over.
        guard !locationQuestionsActive else { return record(.locationActive) }
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

        if let reminder = result.reminder {
            guard await notifications.canNotify() else {
                // Nothing could be shown, so nothing counts as reminded.
                return record(.noPermission)
            }
            await notifications.post(reminder, previous: book.previous(before: reminder.start))
            reminderState = result.state
            persistReminderState()
            return result.outcome
        }

        // No new movement. Maybe a live segment is still running although the phone lies still.
        let stale = ReminderEngine.evaluateStale(
            runs: runs,
            book: book,
            state: result.state,
            settings: settings,
            now: now,
            calendar: .current
        )
        if let staleReminder = stale.reminder {
            guard await notifications.canNotify() else {
                return record(.noPermission)
            }
            await notifications.post(staleReminder)
            reminderState = stale.state
            return record(.sent)
        }

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
    func handleNotificationResponse(actionIdentifier: String, notification: ReminderNotification) async {
        switch notification {
        case .movement(let reminder):
            await handleMovementReminder(actionIdentifier: actionIdentifier, reminder: reminder)
        case .staleSegment(let stale):
            await handleStaleReminder(actionIdentifier: actionIdentifier, stale: stale)
        case .location(let prompt):
            await handleLocationPrompt(actionIdentifier: actionIdentifier, prompt: prompt)
        }
    }

    /// True or False on "Moving detected?" / "Stationary?".
    private func handleLocationPrompt(actionIdentifier: String, prompt: LocationPrompt) async {
        loadSegmentsIfNeeded()
        switch actionIdentifier {
        case NotificationService.trueAction:
            if prompt.kind == .moving {
                showDay(.now)
                await confirmMoving(prompt)
            } else {
                confirmStationary(prompt)
            }
        case NotificationService.falseAction:
            answer(prompt, with: false)
        case UNNotificationDefaultActionIdentifier:
            // The question is shown at the top of today's screen.
            showDay(.now)
        default:
            break
        }
    }

    private func opensApp(_ actionIdentifier: String) -> Bool {
        actionIdentifier == UNNotificationDefaultActionIdentifier
            || actionIdentifier == NotificationService.logAction
            || actionIdentifier == NotificationService.endAction
    }

    /// "Segment still running": open the running segment with the suggested end filled in.
    private func handleStaleReminder(actionIdentifier: String, stale: StaleSegmentReminder) async {
        if actionIdentifier == NotificationService.snoozeAction {
            await notifications.post(stale, delay: NotificationService.snoozeDelay)
            return
        }
        guard opensApp(actionIdentifier) else { return }
        showDay(stale.stoppedAt)
        guard let segment = book.segment(withID: stale.segmentID), segment.isRunning else {
            return // Already ended in the meantime.
        }
        var draft = SegmentDraft(editing: segment)
        draft.end = max(stale.stoppedAt.flooredToMinute, segment.start.addingTimeInterval(60))
        showEditor([draft], origin: .staleSegment(stale))
    }

    private func handleMovementReminder(actionIdentifier: String, reminder: Reminder) async {
        if actionIdentifier == NotificationService.snoozeAction {
            await notifications.post(
                reminder,
                previous: book.previous(before: reminder.start),
                delay: NotificationService.snoozeDelay
            )
            return
        }
        guard opensApp(actionIdentifier) else { return }

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
                location: tracker.authorizationStatus,
                preciseLocation: tracker.hasPreciseLocation
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

    /// Starts or stops the location points and the location wake-ups, asking for permission
    /// if needed. Called on every launch.
    func configureLocation() {
        if settings.locationTracking || wantsLocationWakeUps {
            switch tracker.authorizationStatus {
            case .notDetermined, .authorizedWhenInUse:
                // iOS shows the "Always" prompt at most once; later calls are ignored.
                tracker.requestAlwaysAuthorization()
            default:
                break
            }
        }
        applyLocationSettings()
    }

    /// Wake-ups relaunch the app after larger movements. Location tracking uses them as a
    /// safety net in case iOS ended the app.
    private var wantsLocationWakeUps: Bool {
        settings.locationTracking || (settings.useLocationWakeUps && settings.remindersEnabled)
    }

    private func applyLocationSettings() {
        location.setMonitoring(wantsLocationWakeUps)
        if settings.locationTracking {
            tracker.start(interval: TimeInterval(settings.locationInterval * 60), lastPoint: locationState.latest?.timestamp)
        } else {
            tracker.stop()
        }
    }

    private func locationAuthorizationChanged() {
        refreshPermissions()
        applyLocationSettings()
    }

    // MARK: - Location points

    /// The location points of a day, oldest first.
    func points(on day: Date) -> [LocationPoint] {
        _ = locationRevision
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let stored = loadPoints(dayStart) ?? []
        let unsaved = unsavedPoints.filter { calendar.isDate($0.timestamp, inSameDayAs: dayStart) }
        guard !unsaved.isEmpty else { return stored }
        let known = Set(stored.map(\.id))
        return (stored + unsaved.filter { !known.contains($0.id) }).sorted { $0.timestamp < $1.timestamp }
    }

    var hasLocationPoints: Bool {
        _ = locationRevision
        return !unsavedPoints.isEmpty || !pointStore.storedDays(calendar: .current).isEmpty
    }

    /// True while location points arrive and the questions are on. Motion reminders pause then.
    var locationQuestionsActive: Bool {
        guard settings.locationTracking, settings.locationPrompts, let previous = locationState.previous else { return false }
        let interval = TimeInterval(settings.locationInterval * 60)
        return Date().timeIntervalSince(previous.timestamp) < 2 * interval + 120
    }

    /// The open question for the card on today's screen, as long as it still applies.
    var openLocationPrompt: LocationPrompt? {
        guard let prompt = locationState.pending,
              Date().timeIntervalSince(prompt.askedAt) < 6 * 3600,
              book.running?.id == prompt.segmentID else { return nil }
        return prompt
    }

    /// "Measure now" in the settings.
    func measureLocationNow() {
        tracker.measure(.manual)
    }

    private func recordPoint(_ fix: LocationTracker.Fix) {
        var point = LocationPoint(fix.location, trigger: fix.trigger)
        loadSegmentsIfNeeded()
        if isDataLoaded {
            let result = LocationPromptEngine.evaluate(
                point: point,
                running: book.running,
                state: locationState,
                settings: settings,
                calendar: .current
            )
            locationState = result.state
            if let prompt = result.prompt {
                point.prompt = prompt.kind
                Task { await postLocationPrompt(prompt) }
            }
        } else {
            // Without the segments the questions cannot be decided; just keep the point.
            locationState.latest = point
        }
        persistLocationState()
        unsavedPoints.append(point)
        flushPoints()
        Task { await evaluateReminders() }
    }

    private func postLocationPrompt(_ prompt: LocationPrompt) async {
        guard await notifications.canNotify() else { return }
        await notifications.post(prompt, running: book.running, stationaryDistance: settings.stationaryDistance)
    }

    /// Writes points that are not stored yet into their day files.
    private func flushPoints() {
        guard !unsavedPoints.isEmpty else { return }
        let calendar = Calendar.current
        var saved = Set<UUID>()
        for (day, points) in Dictionary(grouping: unsavedPoints, by: { calendar.startOfDay(for: $0.timestamp) }) {
            guard let existing = loadPoints(day) else { continue }
            let known = Set(existing.map(\.id))
            let merged = (existing + points.filter { !known.contains($0.id) }).sorted { $0.timestamp < $1.timestamp }
            do {
                try pointStore.save(merged, day: day, calendar: calendar)
                pointsCache[day] = merged
                saved.formUnion(points.map(\.id))
            } catch {
                continue
            }
        }
        unsavedPoints.removeAll { saved.contains($0.id) }
        locationRevision += 1
    }

    /// The stored points of a day, or nil while the file cannot be read (locked after a restart).
    private func loadPoints(_ day: Date) -> [LocationPoint]? {
        if let cached = pointsCache[day] {
            return cached
        }
        do {
            let points = try pointStore.load(day: day, calendar: .current)
            pointsCache[day] = points
            return points
        } catch is DecodingError {
            // Damaged: keep a copy and start the day fresh instead of failing forever.
            pointStore.quarantine(day: day, calendar: .current)
            pointsCache[day] = []
            return []
        } catch {
            return nil
        }
    }

    private func setAnswer(_ answer: Bool, forPoint id: UUID, takenAt date: Date) {
        if let index = unsavedPoints.firstIndex(where: { $0.id == id }) {
            unsavedPoints[index].answer = answer
            flushPoints()
            return
        }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        guard var points = loadPoints(day), let index = points.firstIndex(where: { $0.id == id }) else { return }
        points[index].answer = answer
        if (try? pointStore.save(points, day: day, calendar: calendar)) != nil {
            pointsCache[day] = points
            locationRevision += 1
        }
    }

    /// Stores the answer to a question and removes it from the screen and the notification center.
    func answer(_ prompt: LocationPrompt, with answer: Bool) {
        setAnswer(answer, forPoint: prompt.id, takenAt: prompt.askedAt)
        if locationState.pending?.id == prompt.id {
            locationState.pending = nil
            persistLocationState()
        }
        notifications.removeDelivered(prompt)
    }

    /// "True" on "Moving detected?": asks how the user is moving, with the start estimated from
    /// the location points and, if available, the motion sensor.
    func confirmMoving(_ prompt: LocationPrompt) async {
        var answer = MovingAnswer(prompt: prompt, start: prompt.since, activity: nil)
        let now = Date()
        if motion.permission == .authorized,
           let samples = try? await motion.samples(from: prompt.since.addingTimeInterval(-3600), to: max(prompt.askedAt, now)) {
            let runs = MovementDetector.runs(from: samples, until: now, parameters: settings.sensitivity.parameters)
            if let departure = LocationPromptEngine.departure(for: prompt, runs: runs) {
                answer.start = departure.start
                answer.activity = departure.activity
            }
        }
        answer.start = answer.start.flooredToMinute
        sheet = .movingAnswer(answer)
    }

    /// Starts the moving segment chosen in the "How are you moving?" sheet.
    @discardableResult
    func startMoving(_ type: MovementType, at start: Date, answering prompt: LocationPrompt) -> Bool {
        var updated = book
        let now = Date()
        var at = min(start, now)
        if let running = updated.running {
            at = min(max(at, running.start.addingTimeInterval(60)), now)
        } else if let last = updated.previous(before: now), let end = last.end, end > at, end <= now {
            at = end
        }
        updated.startLive(type, at: at, source: .location)
        guard commit(updated) else { return false }
        answer(prompt, with: true)
        return true
    }

    /// "True" on "Stationary?": ends the moving segment where the stop began and starts Stationary.
    func confirmStationary(_ prompt: LocationPrompt) {
        guard let running = book.running, running.id == prompt.segmentID, running.type.isMoving else {
            // The segment changed in the meantime: only keep the answer.
            answer(prompt, with: true)
            return
        }
        var updated = book
        let at = min(max(prompt.since, running.start.addingTimeInterval(60)), Date())
        let stationary = updated.startLive(.stationary, at: at, source: .location)
        guard commit(updated) else { return }
        // Compare the next points with the place where the user stopped.
        locationState.segmentID = stationary.id
        locationState.anchor = locationState.previous
        locationState.lastNearAnchor = locationState.previous
        locationState.stopStart = nil
        locationState.movingAsked = false
        answer(prompt, with: true)
        persistLocationState()
    }

    func deleteLocationPoints() {
        try? pointStore.deleteAll()
        pointsCache = [:]
        unsavedPoints = []
        locationState = LocationPromptState()
        persistLocationState()
        locationRevision += 1
    }

    /// Sends a sample "Moving detected?" question in a few seconds.
    func sendTestLocationPrompt() async {
        let now = Date()
        let prompt = LocationPrompt(
            id: UUID(),
            kind: .moving,
            askedAt: now,
            since: now.addingTimeInterval(-7 * 60).flooredToMinute,
            distance: 650,
            segmentID: book.running?.id
        )
        await notifications.post(prompt, running: book.running, stationaryDistance: settings.stationaryDistance, delay: 5)
    }

    /// Writes the location points as CSV to a temporary file for the share sheet.
    func exportLocationFile(options: CSVOptions, range: ClosedRange<Date>?) async throws -> (url: URL, count: Int) {
        flushPoints()
        let calendar = Calendar.current
        let store = pointStore
        let unsaved = unsavedPoints
        let book = self.book
        let from = range.map { calendar.startOfDay(for: $0.lowerBound) } ?? .distantPast
        let until = range.map { calendar.dayInterval(containing: $0.upperBound).end } ?? .distantFuture
        return try await Task.detached(priority: .userInitiated) {
            var points = store.points(from: from, to: until, calendar: calendar)
            let known = Set(points.map(\.id))
            points += unsaved.filter { !known.contains($0.id) && $0.timestamp >= from && $0.timestamp <= until }
            points.sort { $0.timestamp < $1.timestamp }
            let data = LocationCSVExport.data(for: points, book: book, options: options, timeZone: .current, now: Date())
            let name = LocationCSVExport.fileName(first: points.first?.timestamp, last: points.last?.timestamp, timeZone: .current)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return (url: url, count: points.count)
        }.value
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
            guard commit(updated) else {
                return String(localized: "Could not save")
            }
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
        if defaults.bool(forKey: "debugSeedDemoData") || defaults.bool(forKey: "debugSeedLocationPoints"),
           isDataLoaded, !hasLocationPoints {
            // Today and yesterday, so that a day without other content shows the map card.
            unsavedPoints = DemoData.locationPoints(now: .now) + DemoData.locationPoints(now: .now.addingTimeInterval(-86_400))
            flushPoints()
        }
        if defaults.bool(forKey: "debugLocationTracking") {
            settings.locationTracking = true
        }
        if defaults.bool(forKey: "debugLocationPrompt") {
            // Only in memory: shows the question card without changing the stored state.
            locationState.pending = DemoData.locationPrompt(now: .now, running: book.running)
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
        if defaults.bool(forKey: "debugOpenMap") {
            sheet = .locationMap(selectedDay)
        }
        if defaults.bool(forKey: "debugMovingAnswer") {
            var prompt = DemoData.locationPrompt(now: .now, running: nil)
            prompt.segmentID = book.running?.id
            sheet = .movingAnswer(MovingAnswer(prompt: prompt, start: prompt.since, activity: .walking))
        }
    }
    #endif

    // MARK: - UserDefaults helpers

    private func persistReminderState() {
        Self.encode(reminderState, to: defaults, key: Keys.reminderState)
    }

    private func persistLocationState() {
        Self.encode(locationState, to: defaults, key: Keys.locationState)
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
