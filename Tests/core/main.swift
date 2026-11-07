import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

var failures = 0
func check(_ condition: Bool, _ label: String, line: Int = #line) {
    if !condition { failures += 1; print("FAIL line \(line): \(label)") }
}
func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.0001 } ?? false }

// A clock the tests move by hand.
final class FakeClock { var now = 1000.0 }

func freshFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("splits-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// Pausing leaves paused time off the clock.
do {
    var t = TimerCore(segmentCount: 3)
    t.start(at: 0)
    check(near(t.elapsed(at: 10), 10), "runs")
    t.togglePause(at: 10)
    check(t.phase == .paused && near(t.elapsed(at: 500), 10), "paused clock holds")
    t.togglePause(at: 500)
    check(near(t.elapsed(at: 505), 15), "resume excludes the break")
}

// Undo while running keeps the clock going and rolls time into the reopened split.
do {
    var t = TimerCore(segmentCount: 3)
    t.start(at: 0)
    t.split(at: 10)
    t.split(at: 20)
    check(t.currentIndex == 2, "on third split")
    t.undo()
    check(t.currentIndex == 1 && t.phase == .running, "back on second split, running")
    check(near(t.elapsed(at: 25), 25), "clock unaffected by undo")
    t.split(at: 30)
    check(t.splits.count == 2 && near(t.splits[1], 30), "re-split at new time")
}

// Undoing a finish reopens the last split, paused at the finish time.
do {
    var t = TimerCore(segmentCount: 2)
    t.start(at: 0)
    t.split(at: 10)
    t.split(at: 20)
    check(t.phase == .finished && near(t.elapsed(at: 999), 20), "stops at finish")
    check(!t.split(at: 30), "split after finish does nothing")
    t.undo()
    check(t.phase == .paused && near(t.elapsed(at: 999), 20) && t.currentIndex == 1, "finish undone")
    t.togglePause(at: 1000)
    t.split(at: 1005)
    check(t.phase == .finished && near(t.splits[1], 25), "finishes again")
}

// Guards and edge cases.
do {
    var t = TimerCore(segmentCount: 3)
    check(!t.undo(), "nothing to undo before the start")
    t.start(at: 0)
    check(!t.undo(), "nothing to undo on first split")
    t.split(at: 10)
    check(!t.split(at: 10.1), "double press ignored")
    check(t.splits.count == 1, "only one split from a double press")
    t.undo()
    check(t.split(at: 10.2), "split straight after undo is allowed")
    t.togglePause(at: 11)
    check(t.split(at: 12), "split while paused works")
    check(t.phase == .paused && near(t.splits[1], 11), "split while paused keeps paused time")
}

// Formatting.
check(Format.clockString(0) == "0.00", "zero")
check(Format.clockString(8.256) == "8.25", "seconds")
check(Format.clockString(59.999) == "59.99", "no rollover to 60")
check(Format.clockString(724.5) == "12:04.50", "minutes")
check(Format.clockString(3723.45) == "1:02:03.45", "hours")
check(Format.delta(12.34) == "+12.3", "small delta")
check(Format.delta(-65) == "−1:05", "negative delta")
check(Format.delta(3723) == "+1:02:03", "hour delta")
check(Format.short(3723) == "1:02:03", "short hours")

// Saved after every split, and a crash brings the run back paused.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    model.splitOrStart()
    clock.now += 60
    model.splitOrStart()
    clock.now += 40

    // Second launch with no clean quit, reading only what's on disk.
    let reopened = AppModel(folder: folder, clock: { clock.now })
    check(reopened.wasRecovered && reopened.core.phase == .paused, "recovered paused")
    check(reopened.core.splits.count == 1 && near(reopened.core.splits.first, 60), "split survives crash")
    check(reopened.core.currentIndex == 1, "resumes on the right split")
    reopened.togglePause()
    clock.now += 5
    reopened.splitOrStart()
    check(near(reopened.core.splits.last, 65), "continues from saved time")
}

// Quit keeps the exact clock.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    model.splitOrStart()
    clock.now += 42
    model.saveForQuit()
    let reopened = AppModel(folder: folder, clock: { clock.now })
    check(near(reopened.liveTime(), 42), "clock restored after quit")
}

// Undo is saved too.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    model.splitOrStart()
    clock.now += 10
    model.splitOrStart()
    clock.now += 10
    model.undoSplit()
    let reopened = AppModel(folder: folder, clock: { clock.now })
    check(reopened.core.splits.isEmpty, "undone split stays undone after relaunch")
}

// Sleep pauses the clock.
do {
    let clock = FakeClock()
    let model = AppModel(folder: freshFolder(), clock: { clock.now })
    model.splitOrStart()
    clock.now += 10
    model.pauseForSleep()
    clock.now += 3600
    check(model.core.phase == .paused && near(model.liveTime(), 10), "sleep pauses")
}

/// Plays a whole run where every split takes `step` seconds.
func playRun(_ model: AppModel, _ clock: FakeClock, step: Double) {
    model.splitOrStart()
    for _ in model.segments {
        clock.now += step
        model.splitOrStart()
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

let longList = SplitsConfig(game: "Test", category: "", segments: (1...14).map { Segment(name: "Split \($0)") })

// Comparison against the best run.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    model.updateConfig(longList)

    playRun(model, clock, step: 100)
    check(model.core.phase == .finished && model.isNewBest, "first finish is a best")
    check(model.delta(forSplit: 0) == nil, "no delta on first run")
    model.resetRun()
    check(near(model.comparison.bestTotal, 1400), "best total stored")
    check(model.data.runs.first?.status == .finished, "New Run keeps it finished")

    model.splitOrStart()
    clock.now += 90
    model.splitOrStart()
    check(near(model.delta(forSplit: 0), -10), "ahead by 10")
    check(model.isBestSegment(0), "beat best segment")
    clock.now += 130
    model.splitOrStart()
    check(near(model.delta(forSplit: 1), 20), "behind by 20")
    check(!model.isBestSegment(1), "slower is not a best segment")
    model.resetRun()
    check(model.data.runs.count == 2 && model.data.runs[1].status == .reset, "reset run stays in history")
    check(near(model.data.runs[1].elapsed, 220), "reset run keeps its time")
    check(near(model.comparison.bestTotal, 1400), "reset run can't be the best run")
    check(near(model.comparison.bestSegments[model.segments[0].id], 90), "reset run still counts for best segment")

    // Deleting a junk test run clears it from the comparison.
    let junk = model.data.runs[0].id
    model.deleteRun(id: junk)
    check(model.comparison.bestTotal == nil, "deleted best run is gone")
}

// Renaming a split keeps its comparison.
do {
    let clock = FakeClock()
    let model = AppModel(folder: freshFolder(), clock: { clock.now })
    model.updateConfig(longList)
    playRun(model, clock, step: 100)
    model.resetRun()
    var config = model.data.config
    config.segments[3].name = "Renamed Split"
    model.updateConfig(config)
    model.splitOrStart()
    for _ in 0..<4 { clock.now += 90; model.splitOrStart() }
    check(model.segments[3].name == "Renamed Split", "rename applied")
    check(near(model.delta(forSplit: 3), -40), "renamed split still compares")
    check(!model.canEditSplits, "no editing mid-run")
}

// A corrupt save is kept, not overwritten.
do {
    let folder = freshFolder()
    try! Data("not json".utf8).write(to: folder.appendingPathComponent("data.json"))
    let model = AppModel(folder: folder)
    if case .failed = model.saveState {} else { check(false, "shows a problem") }
    let names = try! FileManager.default.contentsOfDirectory(atPath: folder.path)
    check(names.contains { $0.hasPrefix("data-unreadable") }, "bad file kept")
}

// A chosen picture is kept beside the save file and never touches the run.
do {
    func writeImage(width: Int, height: Int, type: UTType, orientation: Int? = nil) -> URL {
        let url = freshFolder().appendingPathComponent("picture").appendingPathExtension(for: type)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties)
        CGImageDestinationFinalize(destination)
        return url
    }
    func savedSize(_ folder: URL) -> (width: Int, height: Int)? {
        NSBitmapImageRep(data: (try? Data(contentsOf: folder.appendingPathComponent("picture.png"))) ?? Data())
            .map { ($0.pixelsWide, $0.pixelsHigh) }
    }

    let folder = freshFolder()
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    check(model.customPicture == nil, "no custom picture to begin with")

    model.splitOrStart()
    clock.now += 100
    model.splitOrStart()
    model.togglePause()
    let saved = try! Data(contentsOf: folder.appendingPathComponent("data.json"))
    let elapsed = model.core.elapsed(at: clock.now)

    let original = writeImage(width: 3000, height: 2000, type: .png)
    check(model.setPicture(from: original), "a PNG is accepted")
    check(model.customPicture != nil, "the picture shows straight away")
    check(savedSize(folder)?.width == 640, "large pictures are shrunk")
    check(savedSize(folder)?.height == 427, "shrinking keeps the shape")
    check((try? Data(contentsOf: folder.appendingPathComponent("data.json"))) == saved, "choosing a picture leaves the save file alone")
    check(model.core.phase == .paused && model.core.splits.count == 1, "choosing a picture leaves the run alone")
    check(near(model.core.elapsed(at: clock.now), elapsed), "choosing a picture leaves the clock alone")

    try! FileManager.default.removeItem(at: original)
    check(AppModel(folder: folder, clock: { clock.now }).customPicture != nil, "still there next launch after the original is deleted")

    let rotated = writeImage(width: 300, height: 100, type: .jpeg, orientation: 6)
    check(model.setPicture(from: rotated), "a JPEG is accepted")
    check(savedSize(folder).map { $0.height > $0.width } == true, "sideways phone photos come out upright")

    let notImage = freshFolder().appendingPathComponent("notes.png")
    try! Data("not a picture".utf8).write(to: notImage)
    let before = model.customPicture
    check(!model.setPicture(from: notImage), "a file that isn't an image is refused")
    check(model.customPicture === before, "a refused file keeps the current picture")
    check(!model.setPicture(from: folder.appendingPathComponent("missing.png")), "a missing file is refused")

    model.clearPicture()
    check(model.customPicture == nil, "Clear Image leaves no picture")
    check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("picture.png").path), "Clear Image removes the saved copy")
    check(AppModel(folder: folder, clock: { clock.now }).customPicture == nil, "still cleared next launch")
    check(model.setPicture(from: rotated) && model.customPicture != nil, "a picture can be chosen after clearing")
    model.clearPicture()
    check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("data.json").path), "Clear Image leaves the save file")
}

// A new copy starts generic.
do {
    let model = AppModel(folder: freshFolder())
    check(model.data.config.segments.map(\.name) == ["Split 1", "Split 2", "Split 3"], "new copies start with the starter splits")
    check(model.data.presets.count == 1, "new copies start with one preset")
    check(model.title == "Untitled" && model.category.isEmpty, "new copies have a blank title")
    check(model.segments.count == 3, "new copies have a few splits")
    check(model.customPicture == nil, "new copies have no picture")
}

// Redo puts back the exact time.
do {
    var t = TimerCore(segmentCount: 3)
    t.start(at: 0)
    t.split(at: 10)
    t.split(at: 25)
    check(!t.canRedo, "nothing to redo before an undo")
    t.undo()
    t.undo()
    check(t.canRedo && t.splits.isEmpty, "two undos can both be redone")
    t.redo()
    check(t.splits == [10], "first redo brings back the older split")
    t.redo()
    check(t.splits == [10, 25] && !t.canRedo, "second redo brings back the newer split")
    check(near(t.elapsed(at: 40), 40), "redo leaves the clock alone")

    t.undo()
    t.split(at: 50)
    check(t.splits == [10, 50] && !t.canRedo, "a new split clears redo")

    t.split(at: 60)
    check(t.phase == .finished, "last split finishes")
    t.undo()
    check(t.phase == .paused, "undoing the finish pauses")
    t.redo()
    check(t.phase == .finished && t.splits == [10, 50, 60], "redoing the finish finishes again")
    check(near(t.elapsed(at: 999), 60), "redoing the finish keeps the finish time")
}

// Redo is saved, and redoing a finish ends the run again.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    model.splitOrStart()
    for _ in 0..<3 { clock.now += 100; model.splitOrStart() }
    check(model.core.phase == .finished && model.data.runs[0].status == .finished, "run finished")
    model.undoSplit()
    check(model.data.runs[0].status == .inProgress, "undo reopens the run")
    model.redoSplit()
    check(model.core.phase == .finished, "redo finishes it")
    check(model.data.runs[0].status == .finished && near(model.data.runs[0].elapsed, 300), "redo restores the finished run")
    let reopened = AppModel(folder: folder, clock: { clock.now })
    check(reopened.data.runs[0].splits.count == 3, "redo is saved")
}

// A reset run can be picked back up.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    model.splitOrStart()
    clock.now += 100
    model.splitOrStart()
    clock.now += 50
    model.resetRun()
    let id = model.data.runs[0].id
    check(model.data.runs[0].status == .reset && model.core.phase == .idle, "run was reset")

    model.resumeRun(id: id)
    check(model.core.phase == .paused && near(model.liveTime(), 150), "resumes paused at the same time")
    check(model.core.splits.count == 1 && model.data.runs[0].status == .inProgress, "resumes with its splits")
    check(model.data.runs[0].endedAt == nil, "resuming clears the end time")
    check(model.data.runs.count == 1, "resuming doesn't add a run")

    model.togglePause()
    clock.now += 25
    model.splitOrStart()
    check(near(model.core.splits.last, 175), "the clock carries on from where it stopped")
    let reopened = AppModel(folder: folder, clock: { clock.now })
    check(reopened.core.phase == .paused && reopened.core.splits.count == 2, "a resumed run survives a crash")

    let other = AppModel(folder: freshFolder(), clock: { clock.now })
    other.splitOrStart()
    for _ in 0..<3 { clock.now += 10; other.splitOrStart() }
    let finished = other.data.runs[0].id
    other.resetRun()
    other.resumeRun(id: finished)
    check(other.core.phase == .idle, "finished runs can't be resumed")
}

// Runs can be set aside and swapped.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    model.updateConfig(longList)
    model.splitOrStart()
    clock.now += 100
    model.splitOrStart()
    clock.now += 50
    let paper = model.currentRunID!
    model.setAside()
    var run = model.data.runs[0]
    check(run.status == .setAside && near(run.elapsed, 150), "setting aside keeps the time, and stops the clock")
    check(run.splits.count == 1, "setting aside keeps the splits")
    check(model.core.phase == .idle && model.currentRunID == nil, "setting aside frees the timer")
    model.setAside()
    check(model.data.runs[0].status == .setAside, "nothing to set aside when the timer is free")
    clock.now += 9999

    model.addPreset(SplitsConfig(game: "Pset", category: "", segments: ["Q1", "Q2"].map { Segment(name: $0) }))
    model.splitOrStart()
    clock.now += 30
    model.splitOrStart()
    let pset = model.currentRunID!
    check(model.title == "Pset" && model.segments.count == 2, "another run can use the timer")

    let reopened = AppModel(folder: folder, clock: { clock.now })
    check(reopened.data.runs.first { $0.id == paper }?.status == .setAside, "set aside runs survive a restart")
    check(reopened.currentRunID == pset && reopened.core.phase == .paused, "the active run comes back after a restart")

    model.resumeRun(id: paper)
    check(model.currentRunID == paper && model.core.phase == .paused, "resuming swaps runs, paused")
    check(near(model.liveTime(), 150), "time set aside doesn't count")
    check(model.core.splits.count == 1 && model.segments.count == 14, "the run comes back with its own list")
    check(model.title == "Test", "the run comes back with its own title")
    run = model.data.runs.first { $0.id == pset }!
    check(run.status == .setAside && near(run.elapsed, 30), "the other run was set aside automatically")
    check(run.splits.count == 1, "the other run kept its splits")
    check(model.data.config.game == "Test", "resuming selects the run's preset")

    model.togglePause()
    clock.now += 5
    model.splitOrStart()
    check(near(model.core.splits.last, 155), "the clock carries on after swapping")
    check(!model.updateSegmentTimes(runID: paper, to: [1, 2]), "the active run can't be edited")
    check(model.updateSegmentTimes(runID: pset, to: [20]), "a set aside run can be edited")
    check(near(model.data.runs.first { $0.id == pset }?.elapsed, 20), "editing a set aside run moves its time")

    model.deleteRun(id: paper)
    check(model.data.runs.contains { $0.id == paper }, "the active run can't be deleted")
    model.deleteRun(id: pset)
    check(!model.data.runs.contains { $0.id == pset }, "set aside runs can be deleted")
}

// Only runs from the same preset are compared.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    let paper = model.data.selectedPresetID
    model.updateConfig(SplitsConfig(game: "Paper", category: "", segments: ["A", "B"].map { Segment(name: $0) }))
    playRun(model, clock, step: 100)
    model.resetRun()
    check(near(model.comparison.bestTotal, 200), "paper has a best run")
    check(model.attempts == 1, "paper has one attempt")

    model.addPreset(SplitsConfig(game: "Pset", category: "", segments: ["Q1", "Q2", "Q3"].map { Segment(name: $0) }))
    let pset = model.data.selectedPresetID
    check(model.comparison.bestTotal == nil, "a new preset has nothing to compare with")
    check(model.attempts == 0, "attempts are counted per preset")
    check(model.core.segmentCount == 3 && model.title == "Pset", "selecting a preset changes the next run")
    playRun(model, clock, step: 10)
    check(model.isNewBest, "a preset's first finish is its best, whatever other presets did")
    check(model.data.runs[1].presetID == pset, "runs remember their preset")
    model.resetRun()

    model.selectPreset(id: paper)
    check(near(model.comparison.bestTotal, 200), "going back brings back that preset's comparison")
    model.splitOrStart()
    clock.now += 90
    model.splitOrStart()
    check(near(model.delta(forSplit: 0), -10), "a new paper run compares with the old one")
    check(!model.isNewBest, "still mid-run")
    let before = model.data.selectedPresetID
    model.selectPreset(id: pset)
    model.addPreset()
    model.deletePreset(id: paper)
    check(model.data.selectedPresetID == before && model.data.presets.count == 2, "presets can't change during a run")
    model.resetRun()

    model.selectPreset(id: pset)
    model.deletePreset(id: pset)
    check(model.data.presets.map(\.id) == [paper] && model.data.selectedPresetID == paper, "deleting moves to another preset")
    check(model.core.segmentCount == 2, "the timer follows the preset that's left")
    check(model.data.runs.contains { $0.game == "Pset" }, "a deleted preset's runs stay saved")
    model.deletePreset(id: paper)
    check(model.data.presets.count == 1, "the last preset can't be deleted")

    let reopened = AppModel(folder: folder, clock: { clock.now })
    check(reopened.data.selectedPresetID == paper && reopened.data.presets.count == 1, "presets are saved")
}

// Saves from before presets move across.
do {
    let folder = freshFolder()
    let ids = (UUID(), UUID())
    let old = """
    {"config":{"game":"Old Project","category":"Class","segments":[{"id":"\(ids.0)","name":"One"},{"id":"\(ids.1)","name":"Two"}]},
     "runs":[
      {"id":"\(UUID())","startedAt":"2026-11-06T10:00:00Z","endedAt":"2026-11-06T11:00:00Z","status":"finished","game":"Old Project","category":"Class",
       "segments":[{"id":"\(ids.0)","name":"One"},{"id":"\(ids.1)","name":"Two"}],
       "splits":[{"segmentID":"\(ids.0)","name":"One","time":100},{"segmentID":"\(ids.1)","name":"Two","time":300}],"elapsed":300},
      {"id":"\(UUID())","startedAt":"2026-11-06T12:00:00Z","status":"inProgress","game":"Old Project","category":"Class",
       "segments":[{"id":"\(ids.0)","name":"One"},{"id":"\(ids.1)","name":"Two"}],
       "splits":[{"segmentID":"\(ids.0)","name":"One","time":80}],"elapsed":120}]}
    """
    try! Data(old.utf8).write(to: folder.appendingPathComponent("data.json"))
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    if case .failed = model.saveState { check(false, "an old save loads") }
    check(model.data.presets.count == 1 && model.title == "Old Project", "the old list becomes a preset")
    check(model.data.runs.allSatisfy { $0.presetID == model.data.selectedPresetID }, "old runs join that preset")
    check(model.core.phase == .paused && near(model.liveTime(), 120), "an old unfinished run comes back paused")
    check(near(model.comparison.bestTotal, 300), "old runs are compared")
    check(near(model.delta(forSplit: 0), -20), "old comparisons still work")
    check(model.attempts == 2, "old attempts are counted")

    model.togglePause()
    clock.now += 10
    model.saveForQuit()
    let id = model.data.selectedPresetID
    let reopened = AppModel(folder: folder, clock: { clock.now })
    check(reopened.data.selectedPresetID == id && reopened.data.presets.count == 1, "the move only happens once")
    check(reopened.data.runs.allSatisfy { $0.presetID == id }, "old runs stay in the preset")
}

// One backup a day, from before that day's first save.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    var day = Date(timeIntervalSince1970: 1_800_000_000)
    let backups = folder.appendingPathComponent("Backups")
    func names() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).sorted() }
    func launch() -> AppModel { AppModel(folder: folder, clock: { clock.now }, today: { day }) }

    var model = launch()
    model.splitOrStart()
    clock.now += 10
    model.splitOrStart()
    check(names().isEmpty, "nothing to back up on the very first save")

    day += 86400
    model.togglePause()
    check(names().count == 1, "a new day makes a backup, even without a restart")
    let first = names()[0]
    let copy = backups.appendingPathComponent(first)
    let saved = try! JSONDecoder.iso.decode(AppData.self, from: Data(contentsOf: copy))
    check(saved.runs.count == 1 && saved.runs[0].splits.count == 1, "the backup is a readable save")
    let original = try! Data(contentsOf: copy)

    model.togglePause()
    clock.now += 10
    model.splitOrStart()
    check(names() == [first], "only one backup a day")
    model = launch()
    model.togglePause()
    check(names() == [first], "a restart on the same day doesn't add one")
    check((try? Data(contentsOf: copy)) == original, "a day's backup is never overwritten")

    for _ in 0..<14 {
        day += 86400
        model.togglePause()
    }
    check(names().count == 10, "only the last 10 days are kept")
    check(!names().contains(first), "the oldest backups go first")
    check(names().last?.hasPrefix("data-") == true, "backups are named by date")
}

// A backup problem never gets in the way of saving.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    var day = Date(timeIntervalSince1970: 1_800_000_000)
    let model = AppModel(folder: folder, clock: { clock.now }, today: { day })
    model.splitOrStart()
    try! Data("in the way".utf8).write(to: folder.appendingPathComponent("Backups"))
    day += 86400
    clock.now += 10
    model.splitOrStart()
    if case .failed = model.saveState { check(false, "a blocked backup still saves") }
    let reopened = AppModel(folder: folder, clock: { clock.now })
    check(reopened.core.splits.count == 1, "the save went through")
}

// The color rename keeps a saved choice.
check(ColorTheme(rawValue: "magnolia") == .rosa && ColorTheme.rosa.title == "Rosa", "a saved Magnolia choice opens as Rosa")

// Fixing times in a saved run.
do {
    let folder = freshFolder()
    let clock = FakeClock()
    let model = AppModel(folder: folder, clock: { clock.now })
    model.splitOrStart()
    for step in [100.0, 200, 300] { clock.now += step; model.splitOrStart() }
    let id = model.data.runs[0].id
    check(model.updateSegmentTimes(runID: id, to: [40, 260, 300]), "times can be changed")
    let run = model.data.runs[0]
    check(run.splits.map(\.time) == [40, 300, 600], "totals follow the new lengths")
    check(near(run.elapsed, 600), "unchanged overall length stays")
    check(model.core.splits == [40, 300, 600], "the finished run on screen updates")
    check(model.updateSegmentTimes(runID: id, to: [40, 260, 200]), "a run can be shortened")
    check(near(model.data.runs[0].elapsed, 500) && near(model.liveTime(), 500), "shortening moves the final time")
    check(!model.updateSegmentTimes(runID: id, to: [40, -1, 200]), "negative times are refused")
    check(!model.updateSegmentTimes(runID: id, to: [40]), "the wrong number of times is refused")
    check(near(model.data.runs[0].elapsed, 500), "refused edits change nothing")
    check(AppModel(folder: folder, clock: { clock.now }).data.runs[0].splits.map(\.time) == [40, 300, 500], "edits are saved")

    model.resetRun()
    model.splitOrStart()
    check(near(model.comparison.bestTotal, 500), "comparisons use the corrected time")
    check(!model.updateSegmentTimes(runID: model.currentRunID!, to: []), "a run in progress can't be edited")
    clock.now += 100
    model.splitOrStart()
    clock.now += 900
    model.resetRun()
    let reset = model.data.runs[1]
    check(near(reset.elapsed, 1000), "reset run has its time")
    check(model.updateSegmentTimes(runID: reset.id, to: [70]), "reset runs can be edited")
    check(near(model.data.runs[1].elapsed, 970), "time after the last split in a reset run is kept")
}

// Clock detail.
check(Format.clock(3723.45, precision: .hundredths).main == "1:02:03", "hundredths keeps the main part")
check(Format.clock(3723.45, precision: .hundredths).fraction == ".45", "hundredths shows the fraction")
check(Format.clock(3723.45, precision: .seconds).main == "1:02:03" && Format.clock(3723.45, precision: .seconds).fraction.isEmpty, "seconds drops the fraction")
check(Format.clock(8.25, precision: .seconds).main == "0:08", "seconds always shows minutes")
check(Format.clock(3723.45, precision: .minutes).main == "1h 02m", "minutes with hours")
check(Format.clock(1380, precision: .minutes).main == "23m", "minutes alone")
check(Format.clock(20, precision: .minutes).main == "0m", "under a minute")
check(Format.clock(360000, precision: .minutes).main == "100h 00m", "very long runs")
check(Format.live(125, precision: .seconds) == "2:05" && Format.live(125, precision: .minutes) == "2m", "live values follow the setting")
check(Format.liveDelta(125, precision: .minutes) == "+2m" && Format.liveDelta(-5, precision: .seconds) == "−0:05", "live differences follow the setting")

// Typed times.
check(Format.parse("45") == 45 && Format.parse("90") == 90, "plain seconds")
check(Format.parse("12:04") == 724 && Format.parse("12:04.50") == 724.5, "minutes")
check(Format.parse("1:02:03") == 3723 && Format.parse(" 1:02:03.45 ") == 3723.45, "hours")
check(Format.parse("120:00") == 7200 && Format.parse("100:00:00") == 360000, "large leading values")
for bad in ["", "abc", "1:60", "1:60:00", "1:2:3:4", "-5", "1:", ":30", "nan", "inf"] {
    check(Format.parse(bad) == nil, "refuses \(bad.isEmpty ? "blank" : bad)")
}
for time in [0.0, 8.25, 724.5, 3723.45, 360000.0] {
    check(near(Format.parse(Format.clockString(time)), time), "reads back \(Format.clockString(time))")
}

// Splits are shared by name only.
do {
    let config = SplitsConfig(game: "Thesis", category: "Spring", segments: ["Read", "Write"].map { Segment(name: $0) })
    let file = try! SharedSplits(config).encoded()
    let text = String(decoding: file, as: UTF8.self)
    check(text.contains("Thesis") && text.contains("Write"), "the file holds the names")
    let imported = SharedSplits.config(from: file)
    check(imported?.game == "Thesis" && imported?.category == "Spring", "title and subtitle come back")
    check(imported?.segments.map(\.name) == ["Read", "Write"], "splits come back in order")
    check(imported?.segments[0].id != config.segments[0].id, "imported splits don't inherit comparisons")
    check(SharedSplits.config(from: Data("not json".utf8)) == nil, "a bad file is refused")
    check(SharedSplits.config(from: Data("{\"title\":\"a\",\"subtitle\":\"\",\"splits\":[]}".utf8)) == nil, "an empty list is refused")
}

// CSV.
do {
    let run = Run(startedAt: Date(timeIntervalSince1970: 0), status: .finished, game: "Paper, 2", category: "A \"B\"",
                  segments: [Segment(name: "One"), Segment(name: "Two")],
                  splits: [], elapsed: 0)
    var withSplit = run
    withSplit.splits = [SplitRecord(segmentID: run.segments[0].id, name: "One", time: 61.5)]
    let lines = CSV.export([withSplit]).split(separator: "\n").map(String.init)
    check(lines.count == 3, "header plus one row per split")
    check(lines[1].contains("\"Paper, 2\"") && lines[1].contains("\"A \"\"B\"\"\""), "fields escaped")
    check(lines[1].contains("1:01.50") && lines[1].contains("61.50"), "times present")
    check(lines[2].hasSuffix("Two,,,,"), "unfinished split left blank")
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
