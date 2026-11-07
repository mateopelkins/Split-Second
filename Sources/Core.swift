import Foundation

// MARK: - Splits

struct Segment: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
}

struct SplitsConfig: Codable, Equatable {
    var game: String
    var category: String
    var segments: [Segment]

    /// What a new preset starts with.
    static var starter: SplitsConfig {
        SplitsConfig(game: "Untitled", category: "", segments: ["Split 1", "Split 2", "Split 3"].map { Segment(name: $0) })
    }
}

/// A reusable split list. Runs started from the same preset are compared with each other.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var config: SplitsConfig
}

/// A split list as a file, for sharing. It holds names only, never times.
struct SharedSplits: Codable {
    var title: String
    var subtitle: String
    var splits: [String]

    init(_ config: SplitsConfig) {
        title = config.game
        subtitle = config.category
        splits = config.segments.map(\.name)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads a shared file, or returns nil if it isn't one. Splits get new ids, so they
    /// aren't compared against runs of the list they came from.
    static func config(from data: Data) -> SplitsConfig? {
        guard let shared = try? JSONDecoder().decode(SharedSplits.self, from: data), !shared.splits.isEmpty else { return nil }
        return SplitsConfig(game: shared.title, category: shared.subtitle, segments: shared.splits.map { Segment(name: $0) })
    }
}

// MARK: - Runs

struct SplitRecord: Codable, Equatable {
    var segmentID: UUID
    var name: String
    /// Total time on the clock when this split was hit, in seconds.
    var time: Double
}

enum RunStatus: String, Codable {
    case inProgress, finished, reset
    /// Started but put away for later, so another run can use the timer.
    case setAside
}

struct Run: Codable, Identifiable, Equatable {
    var id = UUID()
    var startedAt: Date
    var endedAt: Date?
    var status: RunStatus = .inProgress
    var game: String
    var category: String
    /// The preset this run came from. Runs are only compared within a preset.
    var presetID: UUID?
    /// Snapshot of the split list when the run began.
    var segments: [Segment]
    var splits: [SplitRecord] = []
    /// Time on the clock at the last save. For a finished run this is the final time.
    var elapsed: Double = 0

    /// Time spent on each recorded split, in order.
    var segmentTimes: [Double] {
        var previous = 0.0
        return splits.map { record in
            defer { previous = record.time }
            return record.time - previous
        }
    }
}

struct AppData: Codable, Equatable {
    var presets: [Preset]
    var selectedPresetID: UUID
    var runs: [Run] = []

    init() {
        let first = Preset(config: .starter)
        presets = [first]
        selectedPresetID = first.id
    }

    /// The selected preset's list, which the next run will use.
    var config: SplitsConfig {
        get { presets.first { $0.id == selectedPresetID }?.config ?? presets[0].config }
        set {
            if let index = presets.firstIndex(where: { $0.id == selectedPresetID }) {
                presets[index].config = newValue
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case presets, selectedPresetID, runs, config
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runs = try container.decode([Run].self, forKey: .runs)
        if let saved = try container.decodeIfPresent([Preset].self, forKey: .presets), let first = saved.first {
            let selected = try container.decodeIfPresent(UUID.self, forKey: .selectedPresetID)
            presets = saved
            selectedPresetID = saved.first { $0.id == selected }?.id ?? first.id
        } else {
            // Saves from before presets had one split list, so every run came from it.
            let preset = Preset(config: try container.decode(SplitsConfig.self, forKey: .config))
            presets = [preset]
            selectedPresetID = preset.id
            for index in runs.indices {
                runs[index].presetID = preset.id
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(presets, forKey: .presets)
        try container.encode(selectedPresetID, forKey: .selectedPresetID)
        try container.encode(runs, forKey: .runs)
    }
}

// MARK: - Timer

/// The clock and split list, with no UI or disk access. `now` is a monotonic time in seconds.
struct TimerCore: Equatable {
    enum Phase: String { case idle, running, paused, finished }

    /// Ignores a second split this soon after the last one, so a double press can't skip a split.
    static let splitGuard = 0.3

    private(set) var phase: Phase = .idle
    private(set) var accumulated = 0.0
    private(set) var resumedAt: Double?
    private(set) var splits: [Double] = []
    /// Undone splits, newest last, so redo can restore their exact times.
    private var undone: [Double] = []
    private var lastSplitAt = -Double.infinity
    var segmentCount: Int

    init(segmentCount: Int) {
        self.segmentCount = segmentCount
    }

    /// Rebuilds a run that was interrupted. It always comes back paused.
    init(recovering splits: [Double], elapsed: Double, segmentCount: Int) {
        self.segmentCount = segmentCount
        self.splits = splits
        self.accumulated = max(elapsed, splits.last ?? 0)
        self.phase = .paused
    }

    /// Rebuilds a finished run for display.
    init(finished splits: [Double], segmentCount: Int) {
        self.segmentCount = segmentCount
        self.splits = splits
        self.accumulated = splits.last ?? 0
        self.phase = .finished
    }

    func elapsed(at now: Double) -> Double {
        guard let resumedAt else { return accumulated }
        return accumulated + max(0, now - resumedAt)
    }

    /// Index of the split being worked on, or nil before the start and after the finish.
    var currentIndex: Int? {
        switch phase {
        case .idle, .finished: return nil
        case .running, .paused: return splits.count < segmentCount ? splits.count : nil
        }
    }

    var canUndo: Bool { !splits.isEmpty }
    var canRedo: Bool { !undone.isEmpty && (phase == .running || phase == .paused) }

    mutating func start(at now: Double) {
        guard phase == .idle, segmentCount > 0 else { return }
        phase = .running
        accumulated = 0
        resumedAt = now
        lastSplitAt = now
    }

    /// Records the current split. Also works while paused, keeping the clock stopped.
    @discardableResult
    mutating func split(at now: Double) -> Bool {
        guard phase == .running || phase == .paused else { return false }
        guard now - lastSplitAt >= Self.splitGuard else { return false }
        let time = elapsed(at: now)
        undone.removeAll()
        record(time)
        lastSplitAt = now
        return true
    }

    private mutating func record(_ time: Double) {
        splits.append(time)
        if splits.count >= segmentCount {
            accumulated = time
            resumedAt = nil
            phase = .finished
        }
    }

    mutating func togglePause(at now: Double) {
        switch phase {
        case .running: pause(at: now)
        case .paused:
            phase = .running
            resumedAt = now
        case .idle, .finished: break
        }
    }

    mutating func pause(at now: Double) {
        guard phase == .running else { return }
        accumulated = elapsed(at: now)
        resumedAt = nil
        phase = .paused
    }

    /// Steps back one split. The clock keeps its current state and the time rolls into
    /// the reopened split. Undoing a finish reopens the last split, paused at the finish time.
    @discardableResult
    mutating func undo() -> Bool {
        guard canUndo else { return false }
        undone.append(splits.removeLast())
        lastSplitAt = -Double.infinity
        if phase == .finished { phase = .paused }
        return true
    }

    /// Puts back the last undone split at its original time. A new split clears what can be redone.
    @discardableResult
    mutating func redo() -> Bool {
        guard canRedo, let time = undone.popLast() else { return false }
        record(time)
        return true
    }

    mutating func clear() {
        self = TimerCore(segmentCount: segmentCount)
    }
}

// MARK: - Comparison against past runs

struct Comparison: Equatable {
    /// The finished run with the lowest final time.
    private(set) var bestRunID: UUID?
    private(set) var bestTotal: Double?
    private(set) var bestRunSplits: [UUID: Double] = [:]
    private(set) var bestRunSegments: [UUID: Double] = [:]
    /// Fastest time ever recorded for each split, across all ended runs.
    private(set) var bestSegments: [UUID: Double] = [:]

    init(runs: [Run], excluding excluded: UUID? = nil) {
        let past = runs.filter { $0.id != excluded && ($0.status == .finished || $0.status == .reset) }
        for run in past {
            for (record, time) in zip(run.splits, run.segmentTimes) {
                bestSegments[record.segmentID] = min(bestSegments[record.segmentID] ?? .infinity, time)
            }
        }
        guard let best = past.filter({ $0.status == .finished }).min(by: { $0.elapsed < $1.elapsed }) else { return }
        bestRunID = best.id
        bestTotal = best.elapsed
        for (record, time) in zip(best.splits, best.segmentTimes) {
            bestRunSplits[record.segmentID] = record.time
            bestRunSegments[record.segmentID] = time
        }
    }
}

// MARK: - Formatting

/// How much detail the live clock shows.
enum ClockPrecision: String, CaseIterable, Identifiable {
    case hundredths, seconds, minutes

    var id: String { rawValue }
}

enum Format {
    /// The live clock at the chosen detail.
    static func clock(_ seconds: Double, precision: ClockPrecision) -> (main: String, fraction: String) {
        switch precision {
        case .hundredths: return clock(seconds)
        case .seconds: return (short(seconds), "")
        case .minutes: return (minutes(seconds), "")
        }
    }

    /// A ticking value other than the clock, at the chosen detail.
    static func live(_ seconds: Double, precision: ClockPrecision) -> String {
        precision == .minutes ? minutes(seconds) : short(seconds)
    }

    /// A ticking difference, at the chosen detail.
    static func liveDelta(_ seconds: Double, precision: ClockPrecision) -> String {
        let sign = seconds < 0 ? "−" : "+"
        switch precision {
        case .hundredths: return delta(seconds)
        case .seconds: return sign + short(abs(seconds))
        case .minutes: return sign + minutes(abs(seconds))
        }
    }

    /// Whole minutes, like 23m or 1h 05m.
    static func minutes(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds).rounded(.down)) / 60
        return whole >= 60 ? String(format: "%dh %02dm", whole / 60, whole % 60) : "\(whole)m"
    }

    /// Reads a typed time like 45, 12:04, 12:04.50, or 1:02:03. Returns nil if it isn't one.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let last = parts.last, let seconds = Double(last),
              seconds.isFinite, seconds >= 0, parts.count == 1 || seconds < 60 else { return nil }
        var total = seconds
        var unit = 60.0
        for (index, part) in parts.dropLast().reversed().enumerated() {
            guard let value = Int(part), value >= 0, index == parts.count - 2 || value < 60 else { return nil }
            total += Double(value) * unit
            unit *= 60
        }
        return total
    }

    /// Clock time with hundredths, like 8.25, 12:04.50, or 1:02:03.45.
    static func clock(_ seconds: Double) -> (main: String, fraction: String) {
        let hundredths = Int((max(0, seconds) * 100).rounded(.down))
        let whole = hundredths / 100
        let h = whole / 3600, m = (whole / 60) % 60, s = whole % 60
        let main: String
        if h > 0 {
            main = String(format: "%d:%02d:%02d", h, m, s)
        } else if m > 0 {
            main = String(format: "%d:%02d", m, s)
        } else {
            main = String(s)
        }
        return (main, String(format: ".%02d", hundredths % 100))
    }

    static func clockString(_ seconds: Double) -> String {
        let parts = clock(seconds)
        return parts.main + parts.fraction
    }

    /// Whole seconds, like 0:08, 12:04, or 1:02:03.
    static func short(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds).rounded(.down))
        let h = whole / 3600, m = (whole / 60) % 60, s = whole % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Signed difference, like +12.3, −1:05, or +1:02:03.
    static func delta(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "−" : "+"
        let size = abs(seconds)
        if size < 60 {
            return sign + String(format: "%.1f", (size * 10).rounded(.down) / 10)
        }
        return sign + short(size)
    }
}

// MARK: - CSV

enum CSV {
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { ",\"\n\r".contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func export(_ runs: [Run]) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let header = ["Run Started", "Title", "Subtitle", "Status", "Split #", "Split Name",
                      "Segment Time", "Total Time", "Segment Seconds", "Total Seconds"]
        var lines = [header.joined(separator: ",")]
        for run in runs {
            let times = run.segmentTimes
            for (index, segment) in run.segments.enumerated() {
                let recorded = index < run.splits.count
                let row = [
                    stamp.string(from: run.startedAt), run.game, run.category, statusName(run.status),
                    String(index + 1), recorded ? run.splits[index].name : segment.name,
                    recorded ? Format.clockString(times[index]) : "",
                    recorded ? Format.clockString(run.splits[index].time) : "",
                    recorded ? String(format: "%.2f", times[index]) : "",
                    recorded ? String(format: "%.2f", run.splits[index].time) : "",
                ]
                lines.append(row.map(escape).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func statusName(_ status: RunStatus) -> String {
        switch status {
        case .inProgress: return "In progress"
        case .finished: return "Finished"
        case .reset: return "Reset early"
        case .setAside: return "Set aside"
        }
    }
}
