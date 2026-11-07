import AppKit
import Combine
import Foundation
import ImageIO

/// Publishes the clock for the views that show live time, so nothing else redraws on each tick.
final class Ticker: ObservableObject {
    @Published var now: Double = 0
}

enum SaveState: Equatable {
    case notYet
    case saved(Date)
    case failed(String)
}

/// The timer's color choice in Settings.
enum ColorTheme: String, CaseIterable, Identifiable {
    // Rosa's stored name is its first one, so a saved choice still works.
    case classic, rosa = "magnolia"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic"
        case .rosa: return "Rosa"
        }
    }
}

final class AppModel: ObservableObject {
    @Published private(set) var data: AppData
    @Published private(set) var core: TimerCore
    @Published private(set) var currentRunID: UUID?
    @Published private(set) var comparison: Comparison
    @Published private(set) var saveState: SaveState = .notYet
    @Published private(set) var wasRecovered = false
    @Published var isFloating = true
    @Published var isCompact = false
    @Published var showsControls = true
    @Published var colorTheme: ColorTheme = .classic
    @Published var scale = 1.0
    @Published var hotkeyProblem: String?
    /// The picture chosen in Settings, if any.
    @Published private(set) var customPicture: NSImage?
    @Published var clockPrecision: ClockPrecision = .hundredths {
        didSet {
            tickTimer?.invalidate()
            tickTimer = nil
            refreshTicking()
        }
    }

    static let scaleRange = 0.5...2.0

    let ticker = Ticker()
    let dataFolder: URL
    private let clock: () -> Double
    private let today: () -> Date
    private var tickTimer: Timer?
    private var lastSave = -Double.infinity
    private var lastBackupDay: String?

    private var dataFile: URL { dataFolder.appendingPathComponent("data.json") }
    private var pictureFile: URL { dataFolder.appendingPathComponent("picture.png") }

    static var defaultFolder: URL {
        if let override = ProcessInfo.processInfo.environment["ESSAY_SPLITS_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The app's first name. It stays, so saves from before the rename are still found.
        return support.appendingPathComponent("Essay Splits", isDirectory: true)
    }

    init(folder: URL = AppModel.defaultFolder,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         today: @escaping () -> Date = Date.init) {
        dataFolder = folder
        self.clock = clock
        self.today = today

        var loaded = AppData()
        var problem: String?
        let file = folder.appendingPathComponent("data.json")
        if let raw = try? Data(contentsOf: file) {
            do {
                loaded = try Self.decoder.decode(AppData.self, from: raw)
            } catch {
                // Keep the unreadable file so nothing is lost, and start fresh beside it.
                let aside = folder.appendingPathComponent("data-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: file, to: aside)
                problem = "Old save was unreadable. It was kept as \(aside.lastPathComponent)."
            }
        }

        // An in-progress run means the app quit or crashed mid-essay. Bring it back paused.
        let unfinished = loaded.runs.indices.filter { loaded.runs[$0].status == .inProgress }
        for index in unfinished.dropLast() {
            loaded.runs[index].status = .reset
        }
        let recovered = unfinished.last.map { loaded.runs[$0] }
        if let recovered {
            core = TimerCore(recovering: recovered.splits.map(\.time), elapsed: recovered.elapsed,
                             segmentCount: recovered.segments.count)
        } else {
            core = TimerCore(segmentCount: loaded.config.segments.count)
        }
        data = loaded
        comparison = Self.comparison(in: loaded, preset: recovered?.presetID ?? loaded.selectedPresetID, excluding: recovered?.id)
        currentRunID = recovered?.id
        wasRecovered = recovered != nil
        if let problem { saveState = .failed(problem) }
        ticker.now = clock()
        customPicture = NSImage(contentsOf: pictureFile)
    }

    // MARK: Picture

    /// Saves a small copy beside the save file, so the original can be moved or deleted.
    /// Returns false if the file can't be read as an image, leaving the current picture in place.
    func setPicture(from url: URL) -> Bool {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
            try png.write(to: pictureFile, options: .atomic)
        } catch {
            return false
        }
        customPicture = NSImage(data: png)
        return true
    }

    func clearPicture() {
        try? FileManager.default.removeItem(at: pictureFile)
        customPicture = nil
    }

    // MARK: Reading state

    var currentRun: Run? {
        guard let currentRunID else { return nil }
        return data.runs.first { $0.id == currentRunID }
    }

    /// The splits on screen: the running run's own list, or the config when nothing has started.
    var segments: [Segment] { currentRun?.segments ?? data.config.segments }
    var title: String { currentRun?.game ?? data.config.game }
    var category: String { currentRun?.category ?? data.config.category }
    var attempts: Int { data.runs.filter { $0.presetID == visiblePresetID }.count }
    var canEditSplits: Bool { core.phase == .idle || core.phase == .finished }
    var hasActiveRun: Bool { core.phase == .running || core.phase == .paused }

    /// The preset of the run on screen, or the one the next run will use.
    private var visiblePresetID: UUID { currentRun?.presetID ?? data.selectedPresetID }

    /// True when the finished run on screen is the best finished run.
    var isNewBest: Bool {
        guard core.phase == .finished, let run = currentRun else { return false }
        guard let previous = comparison.bestTotal else { return true }
        return run.elapsed < previous
    }

    func delta(forSplit index: Int) -> Double? {
        guard index < core.splits.count, index < segments.count,
              let target = comparison.bestRunSplits[segments[index].id] else { return nil }
        return core.splits[index] - target
    }

    func segmentTime(forSplit index: Int) -> Double? {
        guard index < core.splits.count else { return nil }
        return core.splits[index] - (index > 0 ? core.splits[index - 1] : 0)
    }

    /// True when this split beat the fastest time ever recorded for it.
    func isBestSegment(_ index: Int) -> Bool {
        guard let time = segmentTime(forSplit: index),
              let best = comparison.bestSegments[segments[index].id] else { return false }
        return time < best
    }

    func liveTime() -> Double { core.elapsed(at: ticker.now) }

    /// Live time on the split in progress.
    func liveSegmentTime() -> Double { liveTime() - (core.splits.last ?? 0) }

    // MARK: Timer actions

    /// Starts the run, or records the current split.
    func splitOrStart() {
        let now = tick()
        switch core.phase {
        case .idle:
            startRun(at: now)
        case .running, .paused:
            guard core.split(at: now) else { return }
            wasRecovered = false
            if core.phase == .finished {
                finishCurrentRun()
            } else {
                writeRun()
            }
        case .finished:
            break
        }
        refreshTicking()
    }

    func togglePause() {
        let now = tick()
        core.togglePause(at: now)
        wasRecovered = false
        writeRun()
        refreshTicking()
    }

    /// Pauses without a key press, for when the Mac goes to sleep.
    func pauseForSleep() {
        guard core.phase == .running else { return }
        core.pause(at: tick())
        writeRun()
        refreshTicking()
    }

    func undoSplit() {
        tick()
        let wasFinished = core.phase == .finished
        guard core.undo() else { return }
        if wasFinished {
            updateRun { run in
                run.status = .inProgress
                run.endedAt = nil
            }
        }
        writeRun()
        refreshTicking()
    }

    func redoSplit() {
        tick()
        guard core.redo() else { return }
        wasRecovered = false
        if core.phase == .finished {
            finishCurrentRun()
        } else {
            writeRun()
        }
        refreshTicking()
    }

    /// Ends the attempt. An unfinished run stays in the history, marked as reset early.
    func resetRun() {
        let now = tick()
        if core.phase == .running || core.phase == .paused {
            let elapsed = core.elapsed(at: now)
            updateRun { run in
                run.status = .reset
                run.endedAt = Date()
                run.elapsed = elapsed
            }
        }
        currentRunID = nil
        core = TimerCore(segmentCount: data.config.segments.count)
        wasRecovered = false
        refreshComparison()
        save()
        refreshTicking()
    }

    /// Puts the active run away, keeping its time and splits, and frees the timer.
    func setAside() {
        guard hasActiveRun else { return }
        core.pause(at: tick())
        writeRun()
        updateRun { $0.status = .setAside }
        currentRunID = nil
        core = TimerCore(segmentCount: data.config.segments.count)
        wasRecovered = false
        refreshComparison()
        save()
        refreshTicking()
    }

    /// Picks a reset or set aside run back up, paused where it stopped. Any active run is
    /// set aside first, so nothing is lost.
    func resumeRun(id: UUID) {
        guard let status = data.runs.first(where: { $0.id == id })?.status, status == .reset || status == .setAside else { return }
        setAside()
        guard let index = data.runs.firstIndex(where: { $0.id == id }) else { return }
        data.runs[index].status = .inProgress
        data.runs[index].endedAt = nil
        let run = data.runs[index]
        if let preset = run.presetID, data.presets.contains(where: { $0.id == preset }) {
            data.selectedPresetID = preset
        }
        currentRunID = id
        core = TimerCore(recovering: run.splits.map(\.time), elapsed: run.elapsed, segmentCount: run.segments.count)
        refreshComparison()
        wasRecovered = true
        save()
        refreshTicking()
    }

    /// Replaces the length of each split in an ended run. Later totals move by the same amounts.
    @discardableResult
    func updateSegmentTimes(runID: UUID, to times: [Double]) -> Bool {
        guard let index = data.runs.firstIndex(where: { $0.id == runID }), data.runs[index].status != .inProgress,
              times.count == data.runs[index].splits.count, times.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        let oldTotal = data.runs[index].splits.last?.time ?? 0
        var total = 0.0
        for (split, time) in times.enumerated() {
            total += time
            data.runs[index].splits[split].time = total
        }
        let run = data.runs[index]
        data.runs[index].elapsed = run.status == .finished ? total : max(total, run.elapsed + total - oldTotal)
        if runID == currentRunID {
            core = TimerCore(finished: run.splits.map(\.time), segmentCount: run.segments.count)
        }
        refreshComparison()
        save()
        return true
    }

    func deleteRun(id: UUID) {
        guard let run = data.runs.first(where: { $0.id == id }), run.status != .inProgress else { return }
        if id == currentRunID {
            currentRunID = nil
            core = TimerCore(segmentCount: data.config.segments.count)
        }
        data.runs.removeAll { $0.id == id }
        refreshComparison()
        save()
    }

    // MARK: Presets

    /// Chooses the split list for the next run.
    func selectPreset(id: UUID) {
        guard canEditSplits, id != data.selectedPresetID, data.presets.contains(where: { $0.id == id }) else { return }
        data.selectedPresetID = id
        if core.phase == .idle {
            core = TimerCore(segmentCount: data.config.segments.count)
        }
        refreshComparison()
        save()
    }

    /// Adds a preset and selects it.
    func addPreset(_ config: SplitsConfig = .starter) {
        guard canEditSplits else { return }
        let preset = Preset(config: config)
        data.presets.append(preset)
        selectPreset(id: preset.id)
    }

    /// Removes a preset. Its runs stay saved. The last preset can't be removed.
    func deletePreset(id: UUID) {
        guard canEditSplits, data.presets.count > 1, let index = data.presets.firstIndex(where: { $0.id == id }) else { return }
        data.presets.remove(at: index)
        if id == data.selectedPresetID {
            data.selectedPresetID = data.presets[max(index - 1, 0)].id
            if core.phase == .idle {
                core = TimerCore(segmentCount: data.config.segments.count)
            }
        }
        refreshComparison()
        save()
    }

    func updateConfig(_ config: SplitsConfig) {
        guard canEditSplits else { return }
        data.config = config
        if core.phase == .idle {
            core = TimerCore(segmentCount: config.segments.count)
        }
        save()
    }

    /// Writes the clock to disk on quit so the run can be recovered.
    func saveForQuit() {
        tick()
        writeRun()
    }

    // MARK: Internals

    @discardableResult
    private func tick() -> Double {
        let now = clock()
        ticker.now = now
        return now
    }

    private static func comparison(in data: AppData, preset: UUID, excluding run: UUID?) -> Comparison {
        Comparison(runs: data.runs.filter { $0.presetID == preset }, excluding: run)
    }

    private func refreshComparison() {
        comparison = Self.comparison(in: data, preset: visiblePresetID, excluding: currentRunID)
    }

    private func startRun(at now: Double) {
        let config = data.config
        guard !config.segments.isEmpty else { return }
        let run = Run(startedAt: Date(), game: config.game, category: config.category,
                      presetID: data.selectedPresetID, segments: config.segments)
        data.runs.append(run)
        currentRunID = run.id
        refreshComparison()
        core = TimerCore(segmentCount: config.segments.count)
        core.start(at: now)
        wasRecovered = false
        save()
    }

    private func finishCurrentRun() {
        let finalTime = core.splits.last ?? 0
        updateRun { run in
            run.status = .finished
            run.endedAt = Date()
            run.elapsed = finalTime
        }
        writeRun()
    }

    private func updateRun(_ change: (inout Run) -> Void) {
        guard let currentRunID, let index = data.runs.firstIndex(where: { $0.id == currentRunID }) else { return }
        change(&data.runs[index])
    }

    /// Copies the clock into the stored run and saves it.
    private func writeRun() {
        let elapsed = liveTime()
        let times = core.splits
        updateRun { run in
            run.splits = zip(run.segments, times).map {
                SplitRecord(segmentID: $0.id, name: $0.name, time: $1)
            }
            run.elapsed = elapsed
        }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
            backUpOncePerDay()
            try Self.encoder.encode(data).write(to: dataFile, options: .atomic)
            saveState = .saved(Date())
            lastSave = clock()
        } catch {
            saveState = .failed("Could not save: \(error.localizedDescription)")
        }
    }

    /// Before the day's first save, copies the save file aside, so a mistake can be undone by
    /// going back to an earlier day. A failed copy never stops the save itself.
    private func backUpOncePerDay() {
        let day = Self.dayFormat.string(from: today())
        guard day != lastBackupDay else { return }
        lastBackupDay = day
        let manager = FileManager.default
        let folder = dataFolder.appendingPathComponent("Backups", isDirectory: true)
        let copy = folder.appendingPathComponent("data-\(day).json")
        guard manager.fileExists(atPath: dataFile.path), !manager.fileExists(atPath: copy.path) else { return }
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? manager.copyItem(at: dataFile, to: copy)
        let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.filter({ $0.hasPrefix("data-") }).sorted().dropLast(Self.backupsKept) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func refreshTicking() {
        guard core.phase == .running else {
            tickTimer?.invalidate()
            tickTimer = nil
            return
        }
        guard tickTimer == nil else { return }
        // Less detail on the clock means fewer redraws, which saves battery.
        let interval: Double
        switch clockPrecision {
        case .hundredths: interval = 1.0 / 15.0
        case .seconds: interval = 0.5
        case .minutes: interval = 2
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = self.tick()
            // Regular saves mean a crash loses seconds at most, not the time since the last split.
            if now - self.lastSave >= 15 { self.writeRun() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private static let backupsKept = 10

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
