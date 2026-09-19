import BamCore
import SwiftUI

/// Leaf over the 30 Hz meter snapshot so only the meters re-render, not the whole strip.
struct StripMeters: View {
    let model: ConsoleViewModel
    let mixID: String?
    let active: Bool
    let height: CGFloat

    var body: some View {
        let left = mixID.map(model.mixLevelLeft) ?? model.masterMeterLeft
        let right = mixID.map(model.mixLevelRight) ?? model.masterMeterRight
        let peakLeft = mixID.map(model.mixPeakLeft) ?? model.masterPeakLeft
        let peakRight = mixID.map(model.mixPeakRight) ?? model.masterPeakRight
        HStack(spacing: 6) {
            Meter(level: left, peak: peakLeft, active: active, width: 5, height: height)
            Meter(level: right, peak: peakRight, active: active, width: 5, height: height)
        }
    }
}

private extension KeyPress {
    /// Perceptual step for ↑/↓ (1 %, ⇧ 5 %); nil for other keys.
    var levelStep: Double? {
        let direction: Double
        switch key {
        case .upArrow: direction = 1
        case .downArrow: direction = -1
        default: return nil
        }
        return direction * (modifiers.contains(.shift) ? 0.05 : 0.01)
    }

    var isMuteToggle: Bool { key == "m" && phase == .down }
}

/// Master strip pinned at the right: the routed hardware device's own volume, with an aggregate meter.
struct MasterStrip: View {
    @Environment(\.theme) private var t
    @Bindable var model: ConsoleViewModel

    @State private var level: Double = 1.0
    @State private var pickingOutput = false
    @State private var showingRecoveryStatus = false
    @FocusState private var focused: Bool

    private var muted: Bool { model.masterMuted }

    var body: some View {
        VStack(spacing: 0) {
            outputSelector
                .frame(maxWidth: .infinity)
                .padding(.init(top: 6, leading: 2, bottom: 8, trailing: 2))

            if model.audioRecoveryDisplayState.isVisible {
                AudioRecoveryPill(
                    state: model.audioRecoveryDisplayState,
                    isPresented: $showingRecoveryStatus,
                    onRestart: { Task { await model.restartAudio() } }
                )
                .padding(.bottom, 8)
            }

            GeometryReader { geo in
                let h = max(80, geo.size.height)
                HStack(spacing: 10) {
                    StripMeters(model: model, mixID: nil, active: !muted, height: h)
                    Fader(value: $level, accentTrack: !muted, dimmed: muted, height: h, linear: true,
                          accessibilityLabel: "Master level",
                          onChange: { model.setOutputVolume($0, origin: "ui:drag") }) {
                        model.setOutputVolume(level)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.top, 10)
            .frame(maxHeight: .infinity)

            HStack(spacing: 1) {
                Text(verbatim: "\(Int((level * 100).rounded()))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(muted ? t.dim : t.text)
                Text("%").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(t.dim)
            }
            .strikethrough(muted)
            .padding(.vertical, 9)

            IconBtn(label: "M", active: muted, danger: true) {
                model.setMasterMuted(!muted)
            }
            .accessibilityLabel("Mute")
            .accessibilityValue(muted ? "on" : "off")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: t.stripW + 16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: t.accent.opacity(0.15), location: 0),
                            .init(color: t.surface, location: 0.6),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(t.accent.opacity(focused ? 1 : 0.32), lineWidth: 1)
                )
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat, .up], action: handleKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Master")
        .padding(.trailing, 12)
        .onAppear { level = model.outputVolume }
        .onChange(of: model.outputVolume) { _, new in level = new }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if let step = press.levelStep {
            if press.phase == .up {
                model.setOutputVolume(level)
            } else {
                level = min(1, max(0, level + step))
                model.setOutputVolume(level, origin: "ui:key")
            }
            return .handled
        }
        if press.isMuteToggle {
            model.setMasterMuted(!muted)
            return .handled
        }
        return .ignored
    }

    private var outputSelector: some View {
        Button { pickingOutput.toggle() } label: {
            VStack(spacing: 7) {
                Image(systemName: model.systemOutputIcon)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(t.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(t.accent.opacity(0.16)))
                Text(model.systemOutputName)
                    .font(.system(size: 12, weight: .semibold)).tracking(-0.1)
                    .foregroundStyle(t.text)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: t.stripW - 4)
                HStack(spacing: 3) {
                    Text("OUTPUT").font(.system(size: 9, design: .monospaced)).foregroundStyle(t.faint)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold)).foregroundStyle(t.faint)
                        .rotationEffect(.degrees(pickingOutput ? 180 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(model.systemOutputName)
        .popover(isPresented: $pickingOutput, arrowEdge: .bottom) {
            OutputList(model: model).environment(\.theme, t)
        }
    }
}

struct AudioRecoveryPill: View {
    @Environment(\.theme) private var t
    let state: AudioRecoveryDisplayState
    @Binding var isPresented: Bool
    let onRestart: () -> Void

    private var tone: Color {
        switch state {
        case .ok: t.accent
        case .recovering: Theme.warning
        case .paused: Theme.danger
        }
    }

    var body: some View {
        Group {
            if state.isActionable {
                Button { isPresented.toggle() } label: {
                    content
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                    AudioRecoveryStatusPopover(
                        state: state,
                        tone: tone,
                        onRestart: {
                            isPresented = false
                            onRestart()
                        }
                    )
                        .environment(\.theme, t)
                }
            } else {
                content
            }
        }
        .help(state.detail)
    }

    private var content: some View {
        HStack(spacing: 5) {
            Image(systemName: state.icon)
                .font(.system(size: 10, weight: .bold))
            Text(state.title)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 8).fill(tone.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tone.opacity(0.32), lineWidth: 0.5))
        .contentShape(Rectangle())
    }
}

private struct AudioRecoveryStatusPopover: View {
    @Environment(\.theme) private var t
    let state: AudioRecoveryDisplayState
    let tone: Color
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: state.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tone)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tone.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.explanationTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(t.text)
                    Text(state.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(t.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 6) {
                statusRow("Reason", state.reason)
                statusRow("Attempts", state.attempts)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Restart Audio", action: onRestart)
            }
        }
        .padding(12)
        .frame(width: 268)
        .background(t.surface2)
        .focusEffectDisabled()
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(t.faint)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(t.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: 24)
    }
}

struct OutputList: View {
    @Environment(\.theme) private var t
    @Bindable var model: ConsoleViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.hardwareOutputDevices.isEmpty {
                Text("No output devices")
                    .font(.system(size: 11.5)).foregroundStyle(t.faint)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                ForEach(model.hardwareOutputDevices) { dev in row(dev) }
            }
        }
        .padding(6)
        .frame(width: 248)
        .background(t.surface2)
        .focusEffectDisabled()
    }

    private func row(_ dev: AudioDevice) -> some View {
        let here = dev.uid == model.systemOutputUID
        return Button {
            model.setSystemOutput(dev.uid)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: dev.outputIcon)
                    .font(.system(size: 13)).foregroundStyle(here ? t.accent : t.dim)
                    .frame(width: 24)
                Text(dev.name)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(t.text).lineLimit(1)
                Spacer(minLength: 6)
                if here {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(t.accent)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(here ? t.accent.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One output device as a channel strip: identity, routed apps, meters + fader, readout, mute.
struct DeviceStrip: View {
    @Environment(\.theme) private var t
    @Bindable var model: ConsoleViewModel
    let mix: Mix

    @State private var level: Double = 1.0
    @State private var renaming = false
    @State private var draftName = ""
    @State private var panel = false
    @StateObject private var emojiCatcher = EmojiCatcher()
    @FocusState private var nameFocused: Bool
    @FocusState private var focused: Bool

    private var muted: Bool { model.deviceMuted(mix.id) }
    private var offline: Bool { model.failedMixIDs.contains(mix.id) }
    private var live: Bool { !muted && !offline }
    private var tone: Color { mix.chipColor }

    var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { geo in
                let h = max(80, geo.size.height)
                HStack(spacing: 10) {
                    StripMeters(model: model, mixID: mix.id, active: live, height: h)
                    Fader(value: $level, accentTrack: live, dimmed: muted, height: h,
                          accessibilityLabel: "\(mix.name) level",
                          onChange: { model.previewDeviceLevel(mix.id, $0) }) {
                        model.setDeviceLevel(mix.id, level)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.top, 10)
            .frame(maxHeight: .infinity)

            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    Text(verbatim: "\(AudioTaper.percent(fromGain: level))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(muted ? t.dim : t.text)
                    Text("%").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(t.dim)
                }
                Text(verbatim: Readout.dbLabel(gain: level))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(t.dim)
            }
            .strikethrough(muted)
            .padding(.vertical, 7)

            HStack(spacing: 6) {
                IconBtn(label: "M", active: muted, danger: true) {
                    model.setDeviceMuted(mix.id, !muted)
                }
                .accessibilityLabel("Mute")
                .accessibilityValue(muted ? "on" : "off")
                if offline {
                    Pill(tone: Theme.danger) {
                        Label("Offline", systemImage: "exclamationmark.triangle.fill").labelStyle(.iconOnly)
                    }
                    .help(model.routerStatusMessage ?? "Offline")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: t.stripW)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(t.surface.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(focused ? t.accent : t.line.opacity(0.7), lineWidth: 1)
                )
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat, .up], action: handleKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mix.name)
        .padding(.horizontal, 6)
        .onAppear { level = mix.level }
        .onChange(of: mix.level) { _, new in level = new }
        .contextMenu {
            if !model.isDefaultDevice(mix.id) {
                Button { draftName = mix.name; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                Divider()
                Button(role: .destructive) { model.deleteDevice(mix.id) } label: {
                    Label("Delete Device", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $renaming) { editSheet }
    }

    // A sheet, not a popover: the system emoji viewer would dismiss a popover.
    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Device")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text)

            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Name")
                fieldWell(focused: nameFocused) {
                    TextField("Device name", text: $draftName)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(t.text)
                        .focused($nameFocused)
                        .onSubmit { commitRename() }
                }
            }

            emojiPicker
            colorPicker

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { renaming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(t.accent)
            }
        }
        .padding(15)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 13).fill(t.surface2)
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(t.line2, lineWidth: 1)))
        .environment(\.theme, t)
        .focusEffectDisabled()
    }

    private static let iconChoices = [
        "🎧", "🎙️", "🔊", "🎵", "🎮",
        "💬", "🎬", "🌐", "📞", "🔔", "📚",
        "💻", "📹", "💳", "❤️", "⭐️",
    ]
    private static let colorHues: [Double] = (0..<8).map { Double($0) / 8.0 }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .tracking(1.0).foregroundStyle(t.dim)
    }

    @ViewBuilder
    private func fieldWell<C: View>(focused: Bool, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(t.sink))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? t.accent : t.line, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 9).inset(by: -2)
                .stroke(t.accent.opacity(0.45), lineWidth: focused ? 2 : 0))
    }

    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Icon")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                identityTile
                ForEach(Self.iconChoices, id: \.self) { glyph in
                    IconTile(selected: mix.emoji == glyph, kind: .emoji(glyph)) {
                        model.setDeviceEmoji(mix.id, glyph)
                    }
                }
                IconTile(selected: false, kind: .more) { emojiCatcher.openPicker() }
            }
        }
    }

    // A preset emoji lights its own tile; the identity tile owns the monogram and any custom emoji.
    private var identityCustom: String? {
        guard let e = mix.emoji, !DeviceIcon.isSymbol(e), !Self.iconChoices.contains(e) else { return nil }
        return e
    }
    private var identitySelected: Bool { mix.emoji == nil || identityCustom != nil }

    // AppKit field so `makeFirstResponder` runs before the emoji viewer opens; otherwise the glyph lands in the name field.
    private var identityTile: some View {
        ZStack {
            EmojiCatcherField(catcher: emojiCatcher) { picked in
                model.setDeviceEmoji(mix.id, picked)
            }
            identityGlyph
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(identitySelected ? t.accent.opacity(0.13) : t.sink))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(identitySelected ? t.accent : t.line, lineWidth: 1))
        .shadow(color: identitySelected ? t.accent.opacity(0.28) : .clear, radius: 6)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { emojiCatcher.openPicker() }
    }

    @ViewBuilder private var identityGlyph: some View {
        if let e = identityCustom {
            Text(e).font(.system(size: 17)).allowsHitTesting(false)
        } else {
            Text(mix.chipMono)
                .font(.system(size: 13, weight: .bold)).tracking(-0.4)
                .foregroundStyle(identitySelected ? t.accent : t.dim)
                .allowsHitTesting(false)
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Color")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 9), spacing: 9) {
                ForEach(Self.colorHues, id: \.self) { h in
                    ColorDot(swatch: Palette.color(hue: h), selected: mix.tone == h, dashed: false) {
                        model.setDeviceColor(mix.id, h)
                    }
                }
                ColorDot(swatch: .clear, selected: mix.tone == nil, dashed: true) {
                    model.setDeviceColor(mix.id, nil)
                }
            }
        }
    }

    private var header: some View {
        Button { panel.toggle() } label: {
            VStack(spacing: 7) {
                Chip(mono: mix.chipMono, color: tone, emoji: mix.emoji, size: 30)
                Text(mix.name)
                    .font(.system(size: 12, weight: .semibold)).tracking(-0.1)
                    .foregroundStyle(t.text).lineLimit(1)
                AppStack(label: appCountLabel, open: panel, apps: model.deviceApps(mix.id))
            }
            .frame(maxWidth: .infinity)
            .padding(.init(top: 6, leading: 2, bottom: 8, trailing: 2))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(panel ? t.surface.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $panel, arrowEdge: .bottom) {
            AppPicker(model: model, mix: mix).environment(\.theme, t)
        }
    }

    private var appCountLabel: String {
        let n = model.deviceAppCount(mix.id)
        return n == 0 ? "add apps" : "\(n)"
    }

    private func commitRename() {
        model.renameDevice(mix.id, to: draftName)
        renaming = false
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if let step = press.levelStep {
            if press.phase == .up {
                model.setDeviceLevel(mix.id, level)
            } else {
                let pos = min(1, max(0, AudioTaper.position(fromGain: level) + step))
                level = AudioTaper.gain(fromPosition: pos)
                model.previewDeviceLevel(mix.id, level)
            }
            return .handled
        }
        if press.isMuteToggle {
            model.setDeviceMuted(mix.id, !muted)
            return .handled
        }
        return .ignored
    }
}

private struct IconTile: View {
    enum Kind { case emoji(String), more }
    @Environment(\.theme) private var t
    let selected: Bool
    let kind: Kind
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? t.accent.opacity(0.13) : t.sink))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? t.accent : t.line, lineWidth: 1))
                .shadow(color: selected ? t.accent.opacity(0.28) : .clear, radius: 6)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case let .emoji(glyph):
            Text(glyph)
                .font(.system(size: 17))
                .opacity(selected ? 1 : hover ? 0.95 : 0.85)
        case .more:
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(hover ? t.text : t.dim)
        }
    }
}

private struct ColorDot: View {
    @Environment(\.theme) private var t
    let swatch: Color
    let selected: Bool
    let dashed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            face
                .frame(width: 24, height: 24)
                .padding(2)
                .overlay(selected ? Circle().stroke(t.accent, lineWidth: 2) : nil)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var face: some View {
        if dashed {
            Circle().fill(.clear)
                .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(t.line2))
                .overlay(Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(t.faint))
        } else {
            Circle().fill(swatch)
                .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5))
        }
    }
}

/// Overlapping app chips + count label shown in the device header.
struct AppStack: View {
    @Environment(\.theme) private var t
    let label: String
    let open: Bool
    let apps: [SourceApp]

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: -7) {
                ForEach(apps.prefix(3)) { a in
                    AppIcon(bundleID: a.bundleID, fallbackMono: a.mono, color: a.color, size: 17, radius: 5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(t.surface, lineWidth: 1.5))
                }
            }
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(t.faint)
                    .lineLimit(1).fixedSize()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold)).foregroundStyle(t.faint)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
        }
        .frame(height: 18)
    }
}

/// Searchable app picker; stays open so several apps can be added in a row.
struct AppPicker: View {
    @Environment(\.theme) private var t
    @Bindable var model: ConsoleViewModel
    let mix: Mix

    @State private var query = ""

    private var results: [AudioApp] {
        let all = model.assignableApps
        guard !query.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(t.faint)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(t.text)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(t.bar)
            .overlay(alignment: .bottom) { Rectangle().fill(t.line).frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 2) {
                    if results.isEmpty {
                        Text("No apps running")
                            .font(.system(size: 11.5)).foregroundStyle(t.faint)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    } else {
                        ForEach(results, id: \.bundleID) { app in row(app) }
                    }
                }
                .padding(6)
            }
            .frame(height: 300)
        }
        .frame(width: 262)
        .background(t.surface2)
        .focusEffectDisabled()
    }

    private func row(_ app: AudioApp) -> some View {
        let curID = model.currentDeviceID(forApp: app.bundleID)
        let here = curID == mix.id
        let mono = String(app.displayName.prefix(2)).uppercased()
        return Button {
            if here {
                model.removeApp(app.bundleID, fromDevice: mix.id)
            } else {
                model.assignApp(app, toDevice: mix.id)
            }
        } label: {
            HStack(spacing: 10) {
                AppIcon(bundleID: app.bundleID, fallbackMono: mono, color: t.accent, size: 24)
                Text(app.displayName)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(t.text).lineLimit(1)
                Spacer(minLength: 6)
                if here {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(t.accent)
                } else if curID != ConsoleViewModel.defaultMixID {
                    Text(model.currentDeviceName(forApp: app.bundleID))
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(t.faint).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(here ? t.accent.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Emoji capture

/// Focuses the hidden AppKit field before opening the emoji viewer so the glyph lands there.
@MainActor
final class EmojiCatcher: ObservableObject {
    fileprivate weak var field: NSTextField?

    func openPicker() {
        guard let field, let win = field.window else { return }
        win.makeFirstResponder(field)
        // Next runloop turn: first responder must settle before the palette opens.
        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
    }
}

private struct EmojiCatcherField: NSViewRepresentable {
    let catcher: EmojiCatcher
    let onPick: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.textColor = .clear
        tf.alignment = .center
        tf.font = .systemFont(ofSize: 1)
        tf.delegate = context.coordinator
        catcher.field = tf
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        catcher.field = nsView
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let onPick: (String?) -> Void
        init(onPick: @escaping (String?) -> Void) { self.onPick = onPick }

        func controlTextDidChange(_ note: Notification) {
            guard let tf = note.object as? NSTextField else { return }
            let picked = EmojiInput.lastGrapheme(of: tf.stringValue)
            tf.stringValue = picked ?? ""
            onPick(picked)
        }
    }
}
