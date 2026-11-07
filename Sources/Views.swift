import AppKit
import SwiftUI

private func hex(_ value: UInt32) -> Color {
    Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
}

/// The colors the timer is drawn with.
struct Palette {
    var background: Color
    /// The window fill. `background` is its top color.
    var backdrop: LinearGradient
    var rowAlt: Color
    var current: LinearGradient
    var text: Color
    var dim: Color
    /// Text on the highlighted row.
    var currentText: Color
    var currentDim: Color
    var currentBehind: Color
    var ahead: Color
    var behind: Color
    var gold: Color
    var best: Color
    var paused: Color
    var buttonFill: Color
    var accentFill: Color
    /// Text on `accentFill` and `warningFill`.
    var onAccent: Color
    var warningFill: Color
    var scheme: ColorScheme
    var swatches: [Color]

    static func of(_ theme: ColorTheme) -> Palette {
        switch theme {
        case .classic: return classic
        case .rosa: return rosa
        }
    }

    private static let classic: Palette = {
        let blue = Color(red: 0.15, green: 0.35, blue: 0.85)
        let green = Color(red: 0.25, green: 0.85, blue: 0.45)
        let red = Color(red: 0.95, green: 0.35, blue: 0.35)
        let gold = Color(red: 0.98, green: 0.80, blue: 0.25)
        let background = Color(red: 0.07, green: 0.07, blue: 0.08)
        let dim = Color.white.opacity(0.55)
        return Palette(
            background: background,
            backdrop: LinearGradient(colors: [background], startPoint: .top, endPoint: .bottom),
            rowAlt: Color.white.opacity(0.035),
            current: LinearGradient(colors: [blue, Color(red: 0.10, green: 0.25, blue: 0.65)], startPoint: .top, endPoint: .bottom),
            text: .white, dim: dim, currentText: .white, currentDim: dim, currentBehind: red,
            ahead: green, behind: red, gold: gold,
            best: Color(red: 0.35, green: 0.70, blue: 1.0),
            paused: Color(red: 0.95, green: 0.70, blue: 0.30),
            buttonFill: Color.white.opacity(0.1), accentFill: blue, onAccent: .white, warningFill: red.opacity(0.75),
            scheme: .dark, swatches: [background, blue, green, gold, red])
    }()

    /// Near-white fading to pink like the flower, with bud green for ahead times.
    private static let rosa: Palette = {
        let white = hex(0xFFFCFB)
        let blush = hex(0xFBE6EC)
        let pink = hex(0xE9B7C8)
        let magenta = hex(0xB8457C)
        let deepMagenta = hex(0x9A2F68)
        let budGreen = hex(0x4A7536)
        let ink = hex(0x3B2A2F)
        let onMagenta = hex(0xFFF6F8)
        return Palette(
            background: white,
            backdrop: LinearGradient(colors: [white, blush], startPoint: .top, endPoint: .bottom),
            rowAlt: pink.opacity(0.18),
            current: LinearGradient(colors: [magenta, deepMagenta], startPoint: .top, endPoint: .bottom),
            text: ink, dim: ink.opacity(0.7),
            currentText: onMagenta, currentDim: onMagenta.opacity(0.9), currentBehind: onMagenta,
            ahead: budGreen, behind: hex(0xB02A5E), gold: hex(0x8F6412), best: hex(0x7C3A8E), paused: hex(0x9A5A74),
            buttonFill: pink.opacity(0.36), accentFill: magenta, onAccent: onMagenta, warningFill: hex(0xB02A5E),
            scheme: .light, swatches: [white, blush, pink, magenta, budGreen, ink])
    }()
}

enum Metrics {
    static let width: CGFloat = 372
    static let rowHeight: CGFloat = 25
    static let compactHeight: CGFloat = 86
    /// Everything in the full view apart from the split rows.
    static let fullChrome: CGFloat = 264
    /// The part of `fullChrome` taken by the Split, Undo, Pause, and Reset buttons.
    static let controlsHeight: CGFloat = 66
}

/// The size setting, as a multiplier on every font and spacing in the timer window.
private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.of(.classic)
}

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// What the timer window can ask the app to open.
struct WindowActions {
    var showEditor: () -> Void
    var showHistory: () -> Void
    var showSettings: () -> Void
}

// MARK: - Root

struct TimerRootView: View {
    @ObservedObject var model: AppModel
    let actions: WindowActions

    private var palette: Palette { .of(model.colorTheme) }

    var body: some View {
        Group {
            if model.isCompact {
                CompactView(model: model, ticker: model.ticker, actions: actions)
            } else {
                FullView(model: model, actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
        .background(palette.backdrop)
        .ignoresSafeArea()
        .environment(\.colorScheme, palette.scheme)
        .environment(\.uiScale, CGFloat(model.scale))
        .environment(\.palette, palette)
    }
}

/// Lets the window be dragged from any empty area.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Full view

private struct FullView: View {
    @ObservedObject var model: AppModel
    let actions: WindowActions

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model, actions: actions)
            SplitList(model: model)
            TimerBlock(model: model, ticker: model.ticker)
            InfoRows(model: model, ticker: model.ticker)
            if model.showsControls {
                Controls(model: model)
            }
            Footer(model: model)
        }
    }
}

private struct Header: View {
    @Environment(\.uiScale) private var s
    @Environment(\.palette) private var theme
    @ObservedObject var model: AppModel
    let actions: WindowActions

    var body: some View {
        HStack(alignment: .top, spacing: 10 * s) {
            Portrait(model: model)
            VStack(alignment: .leading, spacing: 2 * s) {
                HStack(spacing: 4 * s) {
                    Text(model.title).font(.system(size: 15 * s, weight: .semibold)).foregroundStyle(theme.text)
                    Spacer(minLength: 4)
                    // Shorter than the buttons inside it, so the row stays the height of the title.
                    WindowButtons(model: model, actions: actions).frame(height: 18 * s)
                }
                if !model.category.isEmpty {
                    Text(model.category).font(.system(size: 12 * s)).foregroundStyle(theme.dim)
                }
                Text("Attempt \(max(model.attempts, 1))").font(.system(size: 11 * s)).foregroundStyle(theme.dim)
            }
            .lineLimit(1)
        }
        .frame(minHeight: 48 * s, alignment: .top)
        .padding(.horizontal, 12 * s)
        .padding(.top, 12 * s)
        .padding(.bottom, 8 * s)
    }
}

private struct Portrait: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var model: AppModel

    var body: some View {
        if let image = model.customPicture {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72 * s, height: 48 * s)
                .clipShape(RoundedRectangle(cornerRadius: 4 * s))
        }
    }
}

private struct WindowButtons: View {
    @Environment(\.uiScale) private var s
    @Environment(\.palette) private var theme
    @ObservedObject var model: AppModel
    let actions: WindowActions

    var body: some View {
        HStack(spacing: 2 * s) {
            IconButton(symbol: model.isFloating ? "pin.fill" : "pin.slash",
                       tint: model.isFloating ? theme.best : theme.dim,
                       help: model.isFloating ? "Put behind (⌃⌥F)" : "Float (⌃⌥F)") {
                model.isFloating.toggle()
            }
            IconButton(symbol: model.isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                       help: model.isCompact ? "Full view (⌃⌥C)" : "Compact view (⌃⌥C)") {
                model.isCompact.toggle()
            }
            IconButton(symbol: model.showsControls ? "square.grid.2x2.fill" : "square.grid.2x2",
                       tint: model.showsControls ? theme.best : theme.dim,
                       help: model.showsControls ? "Hide buttons" : "Show buttons") {
                model.showsControls.toggle()
            }
            if !model.isCompact {
                IconButton(symbol: "clock.arrow.circlepath", help: "Saved runs", action: actions.showHistory)
                IconButton(symbol: "list.bullet", help: "Edit splits", action: actions.showEditor)
                IconButton(symbol: "gearshape", help: "Settings", action: actions.showSettings)
            }
        }
    }
}

private struct IconButton: View {
    @Environment(\.uiScale) private var s
    @Environment(\.palette) private var theme
    let symbol: String
    var tint: Color?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13 * s))
                .foregroundStyle(tint ?? theme.dim)
                .frame(width: 24 * s, height: 26 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Split rows

private struct SplitList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.segments.enumerated()), id: \.element.id) { index, segment in
                        SplitRow(model: model, ticker: model.ticker, index: index, segment: segment)
                            .id(index)
                    }
                }
            }
            .onChange(of: model.core.splits.count) { count in
                withAnimation { proxy.scrollTo(min(count, model.segments.count - 1), anchor: .center) }
            }
        }
    }
}

private struct SplitRow: View {
    @Environment(\.uiScale) private var s
    @Environment(\.palette) private var theme
    @ObservedObject var model: AppModel
    @ObservedObject var ticker: Ticker
    let index: Int
    let segment: Segment

    private var isCurrent: Bool { model.core.currentIndex == index }
    private var target: Double? { model.comparison.bestRunSplits[segment.id] }

    var body: some View {
        HStack(spacing: 6 * s) {
            Text(segment.name)
                .font(.system(size: 13 * s))
                .foregroundStyle(isCurrent ? theme.currentText : theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(segment.name)
            Spacer(minLength: 4)
            deltaText
                .font(.system(size: 12 * s, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
            timeText
                .font(.system(size: 13 * s).monospacedDigit())
                .lineLimit(1)
                .frame(width: 58 * s, alignment: .trailing)
        }
        .padding(.horizontal, 12 * s)
        .frame(height: Metrics.rowHeight * s)
        .background {
            if isCurrent {
                Rectangle().fill(theme.current)
            } else if index.isMultiple(of: 2) {
                Rectangle().fill(theme.rowAlt)
            }
        }
    }

    @ViewBuilder private var deltaText: some View {
        if let delta = model.delta(forSplit: index) {
            Text(Format.delta(delta))
                .foregroundStyle(model.isBestSegment(index) ? theme.gold : delta < 0 ? theme.ahead : theme.behind)
        } else if isCurrent, let target, model.liveTime() > target {
            Text(Format.liveDelta(model.liveTime() - target, precision: model.clockPrecision)).foregroundStyle(theme.currentBehind)
        }
    }

    @ViewBuilder private var timeText: some View {
        if index < model.core.splits.count {
            Text(Format.short(model.core.splits[index])).foregroundStyle(theme.text)
        } else if let target {
            Text(Format.short(target)).foregroundStyle(isCurrent ? theme.currentDim : theme.dim)
        } else {
            Text("—").foregroundStyle(isCurrent ? theme.currentDim : theme.dim)
        }
    }
}

// MARK: - Clock

private func clockColor(_ model: AppModel, _ theme: Palette) -> Color {
    switch model.core.phase {
    case .idle: return theme.dim
    case .paused: return theme.paused
    case .finished: return model.isNewBest ? theme.best : theme.text
    case .running:
        if let index = model.core.currentIndex, index < model.segments.count,
           let target = model.comparison.bestRunSplits[model.segments[index].id], model.liveTime() > target {
            return theme.behind
        }
        if model.core.splits.count > 0, let delta = model.delta(forSplit: model.core.splits.count - 1), delta > 0 {
            return theme.behind
        }
        return theme.ahead
    }
}

private func stateLabel(_ model: AppModel) -> String {
    switch model.core.phase {
    case .idle: return "READY"
    case .running: return ""
    case .paused: return model.wasRecovered ? "PAUSED · RESTORED" : "PAUSED"
    case .finished: return model.isNewBest ? "NEW BEST" : "FINISHED"
    }
}

private struct ClockText: View {
    @Environment(\.uiScale) private var s
    let seconds: Double
    let size: CGFloat
    let color: Color
    let precision: ClockPrecision

    var body: some View {
        let parts = Format.clock(seconds, precision: precision)
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(parts.main).font(.system(size: size * s, weight: .bold).monospacedDigit())
            Text(parts.fraction).font(.system(size: size * 0.62 * s, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
    }
}

private struct TimerBlock: View {
    @Environment(\.uiScale) private var s
    @Environment(\.palette) private var theme
    @ObservedObject var model: AppModel
    @ObservedObject var ticker: Ticker

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(stateLabel(model))
                .font(.system(size: 11 * s, weight: .semibold))
                .foregroundStyle(clockColor(model, theme))
            Spacer(minLength: 4)
            ClockText(seconds: model.liveTime(), size: 42, color: clockColor(model, theme), precision: model.clockPrecision)
        }
        .padding(.horizontal, 12 * s)
        .frame(height: 58 * s)
    }
}

private struct InfoRows: View {
    @Environment(\.uiScale) private var s
    @Environment(\.palette) private var theme
    @ObservedObject var model: AppModel
    @ObservedObject var ticker: Ticker

    private var previousDelta: Double? {
        let last = model.core.splits.count - 1
        guard last >= 0, last < model.segments.count,
              let time = model.segmentTime(forSplit: last),
              let target = model.comparison.bestRunSegments[model.segments[last].id] else { return nil }
        return time - target
    }

    var body: some View {
        VStack(spacing: 3 * s) {
            HStack {
                Text("This Split")
                Spacer()
                Text(model.core.currentIndex == nil ? "—" : Format.live(model.liveSegmentTime(), precision: model.clockPrecision))
                    .monospacedDigit()
            }
            HStack {
                Text("Previous Segment")
                Spacer()
                if let delta = previousDelta {
                    Text(Format.delta(delta)).monospacedDigit()
                        .foregroundStyle(delta < 0 ? theme.ahead : theme.behind)
                } else {
                    Text("—")
                }
            }
        }
        .font(.system(size: 12 * s))
        .foregroundStyle(theme.dim)
        .padding(.horizontal, 12 * s)
        .padding(.bottom, 8 * s)
    }
}

// MARK: - Controls

private struct Controls: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var model: AppModel
    @State private var confirmingReset = false

    private var isFinished: Bool { model.core.phase == .finished }
    private var isPaused: Bool { model.core.phase == .paused }
    private var isActive: Bool { model.core.phase == .running || isPaused }

    private var splitTitle: String {
        if model.core.phase == .idle { return "Start" }
        return model.core.splits.count == model.segments.count - 1 ? "Finish" : "Split"
    }

    private var resetTitle: String {
        if isFinished { return "New Run" }
        return confirmingReset ? "Really reset?" : "Reset"
    }

    var body: some View {
        VStack(spacing: 6 * s) {
            HStack(spacing: 6 * s) {
                ControlButton(title: splitTitle, symbol: model.core.phase == .idle ? "play.fill" : "forward.end.fill", hint: "⌃⌥S", prominent: true,
                              action: model.splitOrStart)
                    .disabled(isFinished)
                HStack(spacing: 6 * s) {
                    ControlButton(title: "Undo Split", symbol: "arrow.uturn.backward", hint: "⌃⌥Z",
                                  action: model.undoSplit)
                        .disabled(!model.core.canUndo)
                    RedoButton(action: model.redoSplit)
                        .disabled(!model.core.canRedo)
                }
            }
            HStack(spacing: 6 * s) {
                ControlButton(title: isPaused ? "Resume" : "Pause", symbol: isPaused ? "play" : "pause.fill", hint: "⌃⌥P",
                              action: model.togglePause)
                    .disabled(!isActive)
                ControlButton(title: resetTitle, symbol: isFinished ? "plus" : "xmark", hint: "",
                              warning: confirmingReset, action: resetTapped)
                    .disabled(model.core.phase == .idle)
            }
        }
        .padding(.horizontal, 12 * s)
    }

    /// A mid-run reset takes two clicks, since one stray click would end hours of timing.
    private func resetTapped() {
        guard !isFinished, !confirmingReset else {
            confirmingReset = false
            model.resetRun()
            return
        }
        confirmingReset = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmingReset = false }
    }
}

private struct ControlButton: View {
    @Environment(\.uiScale) private var s
    @Environment(\.palette) private var theme
    let title: String
    let symbol: String
    let hint: String
    var prominent = false
    var warning = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5 * s) {
                Image(systemName: symbol).font(.system(size: 10 * s))
                Text(title).font(.system(size: 12 * s, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(hint).font(.system(size: 10 * s)).opacity(0.6)
            }
            .padding(.horizontal, 9 * s)
            .frame(maxWidth: .infinity)
            .frame(height: 30 * s)
            .foregroundStyle(prominent || warning ? theme.onAccent : theme.text)
            .background(fill, in: RoundedRectangle(cornerRadius: 6 * s))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
    }

    private var fill: Color {
        if warning { return theme.warningFill }
        return prominent ? theme.accentFill : theme.buttonFill
    }
}

private struct RedoButton: View {
    @Environment(\.uiScale) private var s
    @Environment(\.palette) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.forward")
                .font(.system(size: 10 * s))
                .frame(width: 30 * s, height: 30 * s)
                .foregroundStyle(theme.text)
                .background(theme.buttonFill, in: RoundedRectangle(cornerRadius: 6 * s))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help("Redo split (⌃⌥R)")
    }
}

private struct Footer: View {
    @Environment(\.uiScale) private var s
    @Environment(\.palette) private var theme
    @ObservedObject var model: AppModel

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        HStack(spacing: 4 * s) {
            if let problem = model.hotkeyProblem {
                label(problem, symbol: "exclamationmark.triangle.fill", color: theme.behind)
            } else {
                switch model.saveState {
                case .notYet:
                    EmptyView()
                case .saved(let date):
                    label("Saved \(Self.time.string(from: date))", symbol: "checkmark.circle.fill", color: theme.ahead)
                case .failed(let message):
                    label(message, symbol: "exclamationmark.triangle.fill", color: theme.behind)
                }
            }
            Spacer(minLength: 4)
            Text(model.showsControls ? "⌃⌥F float · ⌃⌥C compact" : "⌃⌥ S split · Z undo · P pause")
                .font(.system(size: 10 * s))
                .foregroundStyle(theme.dim)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12 * s)
        .frame(height: 28 * s)
    }

    private func label(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 4 * s) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(theme.dim).lineLimit(1).truncationMode(.tail).help(text)
        }
        .font(.system(size: 10 * s))
    }
}

// MARK: - Compact view

private struct CompactView: View {
    @Environment(\.uiScale) private var s
    @Environment(\.palette) private var theme
    @ObservedObject var model: AppModel
    @ObservedObject var ticker: Ticker
    let actions: WindowActions

    private var heading: String {
        switch model.core.phase {
        case .idle: return "Next: \(model.segments.first?.name ?? "")"
        case .finished: return stateLabel(model).capitalized
        case .running, .paused:
            return model.core.currentIndex.map { model.segments[$0].name } ?? ""
        }
    }

    private var position: String {
        let done = min(model.core.splits.count + 1, model.segments.count)
        return "\(done)/\(model.segments.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6 * s) {
                Text(heading)
                    .font(.system(size: 13 * s, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(heading)
                Spacer(minLength: 2)
                Text(position).font(.system(size: 11 * s).monospacedDigit()).foregroundStyle(theme.dim)
                WindowButtons(model: model, actions: actions)
            }
            HStack(alignment: .center, spacing: 2 * s) {
                if model.showsControls {
                    IconButton(symbol: model.core.phase == .idle ? "play.fill" : "forward.end.fill", tint: theme.text, help: "Start or split (⌃⌥S)", action: model.splitOrStart)
                        .disabled(model.core.phase == .finished)
                    IconButton(symbol: model.core.phase == .paused ? "play" : "pause.fill", tint: theme.text,
                               help: "Pause or resume (⌃⌥P)", action: model.togglePause)
                    IconButton(symbol: "arrow.uturn.backward", tint: theme.text, help: "Undo split (⌃⌥Z)", action: model.undoSplit)
                        .disabled(!model.core.canUndo)
                    if model.core.canRedo {
                        IconButton(symbol: "arrow.uturn.forward", tint: theme.text, help: "Redo split (⌃⌥R)", action: model.redoSplit)
                    }
                }
                Spacer(minLength: 4)
                ClockText(seconds: model.liveTime(), size: 30, color: clockColor(model, theme), precision: model.clockPrecision)
            }
        }
        .padding(.horizontal, 12 * s)
        .padding(.vertical, 8 * s)
    }
}

// MARK: - Split editor

struct SplitsEditorView: View {
    @ObservedObject var model: AppModel
    @State private var draft: SplitsConfig
    @State private var importProblem: String?
    /// File dialogs open as sheets on this window, so they stay over a full-screen app.
    let hostWindow: () -> NSWindow?
    let close: () -> Void

    init(model: AppModel, hostWindow: @escaping () -> NSWindow? = { nil }, close: @escaping () -> Void) {
        self.model = model
        self.hostWindow = hostWindow
        self.close = close
        _draft = State(initialValue: model.data.config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Preset", selection: presetBinding) {
                    ForEach(model.data.presets) { preset in
                        Text(preset.config.game.isEmpty ? "Untitled" : preset.config.game).tag(preset.id)
                    }
                }
                Button("New") {
                    keepDraft()
                    model.addPreset()
                }
                Button("Delete", action: deletePreset)
                    .disabled(model.data.presets.count < 2)
            }
            .disabled(!model.canEditSplits)
            HStack {
                LabeledField(label: "Title", text: $draft.game)
                LabeledField(label: "Subtitle", text: $draft.category)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(draft.segments.enumerated()), id: \.element.id) { index, segment in
                        HStack(spacing: 6) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                            TextField("Split name", text: nameBinding(for: segment.id))
                                .textFieldStyle(.roundedBorder)
                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == draft.segments.count - 1)
                            Button { draft.segments.insert(Segment(name: ""), at: index + 1) } label: { Image(systemName: "plus") }
                                .help("Add a split below")
                            Button { draft.segments.remove(at: index) } label: { Image(systemName: "trash") }
                                .help("Remove this split")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.trailing, 8)
            }
            if let note = importProblem ?? (model.canEditSplits ? nil : "Can't edit during a run") {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Add Split") { draft.segments.append(Segment(name: "")) }
                Button("Import…", action: importSplits)
                    .disabled(!model.canEditSplits)
                Button("Export…", action: exportSplits)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canEditSplits || draft.segments.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 480)
        .onChange(of: model.data.selectedPresetID) { _ in draft = model.data.config }
    }

    /// Changes to the current preset are kept when moving to another.
    private var presetBinding: Binding<UUID> {
        Binding(get: { model.data.selectedPresetID }, set: { id in
            keepDraft()
            model.selectPreset(id: id)
        })
    }

    private func keepDraft() {
        if model.canEditSplits, !draft.segments.isEmpty {
            model.updateConfig(cleaned)
        }
    }

    private func deletePreset() {
        guard let window = hostWindow() else { return }
        let id = model.data.selectedPresetID
        let alert = NSAlert()
        alert.messageText = "Delete this preset?"
        alert.informativeText = model.data.config.game
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { model.deletePreset(id: id) }
        }
    }

    /// Binds by id, so a row's field stays valid while rows move or disappear.
    private func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { draft.segments.first { $0.id == id }?.name ?? "" },
            set: { name in
                if let index = draft.segments.firstIndex(where: { $0.id == id }) {
                    draft.segments[index].name = name
                }
            })
    }

    private func move(_ index: Int, by offset: Int) {
        draft.segments.swapAt(index, index + offset)
    }

    private func importSplits() {
        guard let window = hostWindow() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            if let config = (try? Data(contentsOf: url)).flatMap(SharedSplits.config) {
                keepDraft()
                model.addPreset(config)
                importProblem = nil
            } else {
                importProblem = "Couldn't read that file"
            }
        }
    }

    private func exportSplits() {
        guard let window = hostWindow() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = draft.game.replacingOccurrences(of: "/", with: "-") + " splits.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try SharedSplits(draft).encoded().write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private var cleaned: SplitsConfig {
        var config = draft
        for index in config.segments.indices {
            let name = config.segments[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            config.segments[index].name = name.isEmpty ? "Untitled" : name
        }
        return config
    }

    private func save() {
        model.updateConfig(cleaned)
        close()
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// The image picker opens as a sheet on this window, so it stays over a full-screen app.
    var hostWindow: () -> NSWindow? = { nil }
    /// Called once a size is chosen, so the window can step clear of the resized timer.
    var sizeChosen: () -> Void = {}
    @State private var pictureProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Timer size").font(.headline)
                Spacer()
                Text("\(Int((model.scale * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $model.scale, in: AppModel.scaleRange, step: 0.05) { editing in
                if !editing { sizeChosen() }
            }
            HStack {
                ForEach([0.7, 1.0, 1.3], id: \.self) { preset in
                    Button("\(Int((preset * 100).rounded()))%") {
                        model.scale = preset
                        sizeChosen()
                    }
                }
                Spacer()
            }
            Divider()
            Text("Clock").font(.headline)
            Picker("Clock", selection: $model.clockPrecision) {
                Text("0:00.00").tag(ClockPrecision.hundredths)
                Text("0:00").tag(ClockPrecision.seconds)
                Text("0m").tag(ClockPrecision.minutes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            Text("Colors").font(.headline)
            HStack(spacing: 8) {
                ForEach(ColorTheme.allCases) { theme in
                    ThemeCard(theme: theme, isSelected: model.colorTheme == theme) { model.colorTheme = theme }
                }
            }
            Divider()
            Text("Picture").font(.headline)
            HStack(spacing: 12) {
                if model.customPicture != nil {
                    Portrait(model: model)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 72, height: 48)
                        .overlay { Text("None").font(.caption).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button("Change Image…", action: chooseImage)
                    Button("Clear Image") {
                        model.clearPicture()
                        pictureProblem = nil
                    }
                    .disabled(model.customPicture == nil)
                }
            }
            if let pictureProblem {
                Text(pictureProblem).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Button("Quit Split") { NSApp.terminate(nil) }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func chooseImage() {
        guard let window = hostWindow() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            pictureProblem = model.setPicture(from: url) ? nil : "Couldn't read that image"
        }
    }
}

private struct ThemeCard: View {
    @Environment(\.palette) private var current
    let theme: ColorTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(Array(Palette.of(theme).swatches.enumerated()), id: \.offset) { _, color in
                        Rectangle().fill(color)
                    }
                }
                .frame(height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35)) }
                HStack(spacing: 4) {
                    Text(theme.title).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    Spacer(minLength: 0)
                    if isSelected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? current.accentFill : Color.secondary.opacity(0.35), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Gives Settings, Edit Splits, and Saved Runs the timer's colors.
struct ThemedWindowContent<Content: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder let content: Content

    private var palette: Palette { .of(model.colorTheme) }

    var body: some View {
        content
            .background(palette.backdrop)
            .environment(\.palette, palette)
            .environment(\.colorScheme, palette.scheme)
            .tint(palette.accentFill)
    }
}

// MARK: - Run history

struct HistoryView: View {
    @Environment(\.palette) private var theme
    @ObservedObject var model: AppModel
    /// Dialogs open as sheets on this window, so they stay over a full-screen app.
    var hostWindow: () -> NSWindow? = { nil }
    @State private var selection: UUID?
    /// The split lengths being typed, while editing a run's times.
    @State private var draftTimes: [String]?

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private struct RunGroup: Identifiable {
        let id: String
        let title: String
        let runs: [Run]
    }

    private var runs: [Run] { model.data.runs.sorted { $0.startedAt > $1.startedAt } }
    private var selected: Run? { runs.first { $0.id == selection } }
    private var inProgress: [Run] { runs.filter { $0.status == .inProgress || $0.status == .setAside } }

    /// Ended runs, grouped by the preset they came from.
    private var groups: [RunGroup] {
        let ended = runs.filter { $0.status == .finished || $0.status == .reset }
        var seen: [UUID?] = []
        for run in ended where !seen.contains(run.presetID) {
            seen.append(run.presetID)
        }
        return seen.map { preset in
            let members = ended.filter { $0.presetID == preset }
            let title = model.data.presets.first { $0.id == preset }?.config.game ?? members[0].game
            return RunGroup(id: preset?.uuidString ?? "none", title: title.isEmpty ? "Untitled" : title, runs: members)
        }
    }

    private var bestIDs: Set<UUID> { Set(groups.compactMap { Comparison(runs: $0.runs).bestRunID }) }
    private var selectedIsActive: Bool { model.hasActiveRun && selected?.id == model.currentRunID }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $selection) {
                    if !inProgress.isEmpty {
                        Section("In Progress") {
                            ForEach(inProgress) { run in row(run, title: run.game.isEmpty ? "Untitled" : run.game) }
                        }
                    }
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.runs) { run in row(run, title: Self.stamp.string(from: run.startedAt)) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .disabled(draftTimes != nil)
                .frame(width: 250)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if draftTimes != nil {
                    Spacer()
                    Button("Cancel") { draftTimes = nil }.keyboardShortcut(.cancelAction)
                    Button("Save", action: saveTimes)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draftIsValid)
                } else {
                    Button("Delete Run", action: deleteSelected)
                        .disabled(selected == nil || selected?.status == .inProgress)
                    Button("Edit Times") { draftTimes = selected?.segmentTimes.map(Format.clockString) }
                        .disabled(selected == nil || selected?.status == .inProgress || selected?.splits.isEmpty == true)
                    if selectedIsActive {
                        Button("Set Aside") { model.setAside() }
                    } else {
                        Button("Resume Run") {
                            if let run = selected { model.resumeRun(id: run.id) }
                        }
                        .disabled(selected?.status != .reset && selected?.status != .setAside)
                    }
                    Spacer()
                    Button("Show File") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.dataFolder.appendingPathComponent("data.json")])
                    }
                    Button("Export All…") { export(model.data.runs, name: "\(model.data.config.game) all runs") }
                        .disabled(runs.isEmpty)
                    Button("Export Run…") {
                        if let run = selected { export([run], name: exportName(for: run)) }
                    }
                    .disabled(selected == nil)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { selection = inProgress.first?.id ?? runs.first?.id }
    }

    private func row(_ run: Run, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if bestIDs.contains(run.id) {
                    Text("BEST").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.best)
                }
            }
            Text("\(CSV.statusName(run.status)) · \(Format.short(run.elapsed)) · \(run.splits.count)/\(run.segments.count) splits")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .tag(run.id)
    }

    @ViewBuilder private var detail: some View {
        if let run = selected {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Split")
                        Text("Segment").gridColumnAlignment(.trailing)
                        Text("Total").gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    let times = run.segmentTimes
                    ForEach(Array(run.segments.enumerated()), id: \.element.id) { index, segment in
                        let recorded = index < run.splits.count
                        GridRow {
                            Text(recorded ? run.splits[index].name : segment.name)
                            if recorded, draftTimes != nil {
                                TextField("", text: draftBinding(index))
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 96)
                                Text(draftTotal(through: index).map(Format.clockString) ?? "—")
                            } else {
                                Text(recorded ? Format.clockString(times[index]) : "—")
                                Text(recorded ? Format.clockString(run.splits[index].time) : "—")
                            }
                        }
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(recorded ? .primary : .secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(runs.isEmpty ? "No saved runs" : "Pick a run")
                .foregroundStyle(.secondary)
        }
    }

    private func draftBinding(_ index: Int) -> Binding<String> {
        Binding(get: { draftTimes?[index] ?? "" }, set: { draftTimes?[index] = $0 })
    }

    private var draftIsValid: Bool { draftTimes?.allSatisfy { Format.parse($0) != nil } ?? false }

    private func draftTotal(through index: Int) -> Double? {
        guard let draftTimes else { return nil }
        var total = 0.0
        for text in draftTimes.prefix(index + 1) {
            guard let time = Format.parse(text) else { return nil }
            total += time
        }
        return total
    }

    /// A field left as it was keeps its exact time, which has more detail than the field shows.
    private func saveTimes() {
        guard let run = selected, let draftTimes else { return }
        let times = zip(draftTimes, run.segmentTimes).map { text, original in
            text == Format.clockString(original) ? original : Format.parse(text)
        }
        guard model.updateSegmentTimes(runID: run.id, to: times.compactMap { $0 }) else { return }
        self.draftTimes = nil
    }

    private func exportName(for run: Run) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(run.game) \(day.string(from: run.startedAt))"
    }

    private func export(_ runs: [Run], name: String) {
        guard let window = hostWindow() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try CSV.export(runs).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private func deleteSelected() {
        guard let run = selected, let window = hostWindow() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this run?"
        alert.informativeText = Self.stamp.string(from: run.startedAt)
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            model.deleteRun(id: run.id)
            selection = runs.first?.id
        }
    }
}
