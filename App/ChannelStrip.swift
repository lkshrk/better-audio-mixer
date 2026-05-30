import BamCore
import SwiftUI

/// Global master strip pinned at the right: one fader scaling every mix's output
/// (folds into each MixSpec.master in the engine), with an aggregate meter.
struct MasterStrip: View {
    @Environment(\.theme) private var t
    @Bindable var model: ConsoleViewModel

    @State private var level: Double = 1.0
    @State private var pickingOutput = false

    var body: some View {
        VStack(spacing: 0) {
            outputSelector
                .frame(maxWidth: .infinity)
                .padding(.init(top: 6, leading: 2, bottom: 8, trailing: 2))

            GeometryReader { geo in
                let h = max(80, geo.size.height)
                HStack(spacing: 10) {
                    Meter(level: model.masterMeter, active: !model.masterMuted, width: 7, height: h)
                    Meter(level: model.masterMeter, active: !model.masterMuted, width: 7, height: h)
                    Fader(value: $level, accentTrack: !model.masterMuted, height: h, linear: true) {
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
                    .foregroundStyle(t.text)
                Text("%").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(t.dim)
            }
            .padding(.vertical, 9)

            IconBtn(label: "M", active: model.masterMuted, danger: true) {
                model.setMasterMuted(!model.masterMuted)
            }
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
                        .strokeBorder(t.accent.opacity(0.32), lineWidth: 1)
                )
        )
        .padding(.trailing, 12)
        .onAppear { level = model.outputVolume }
        .onChange(of: model.outputVolume) { _, new in level = new }
    }

    /// Hardware-output selector that replaces the old "Master / STEREO" identity:
    /// picks the physical device the Default output feeds; the fader below then
    /// drives that device's own OS volume.
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

/// Popover list of hardware output devices, centered under the master strip's
/// output selector — mirrors the app picker's presentation for consistency.
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

/// One output device as a vertical channel strip: renamable identity + the apps
/// routed into it, a single master meter + fader, dB readout, and mute. Apps are
/// a membership list (added via the panel); the fader controls the whole device.
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
                    Meter(level: model.mixLevel(mix.id), active: live, width: 7, height: h)
                    Meter(level: model.mixLevel(mix.id), active: live, width: 7, height: h)
                    Fader(value: $level, accentTrack: live, height: h) {
                        model.setDeviceLevel(mix.id, level)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.top, 10)
            .frame(maxHeight: .infinity)

            HStack(spacing: 1) {
                Text(verbatim: "\(AudioTaper.percent(fromGain: level))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.text)
                Text("%").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(t.dim)
            }
            .padding(.vertical, 9)

            HStack(spacing: 6) {
                IconBtn(label: "M", active: muted, danger: true) {
                    model.setDeviceMuted(mix.id, !muted)
                }
                if offline {
                    Pill(tone: Color(hex: "ff5b5b")) {
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
                        .strokeBorder(t.line.opacity(0.7), lineWidth: 1)
                )
        )
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

    // A sheet (not a popover) so the system emoji viewer can open over it without
    // dismissing it or shoving the window to the back.
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

    // SF Symbol line glyphs — one monochrome icon language, no glossy color emoji.
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

    // The identity tile owns the default monogram and any *custom* emoji (one
    // not in the preset grid); a preset selection lights its own tile instead.
    private var identityCustom: String? {
        guard let e = mix.emoji, !DeviceIcon.isSymbol(e), !Self.iconChoices.contains(e) else { return nil }
        return e
    }
    private var identitySelected: Bool { mix.emoji == nil || identityCustom != nil }

    // First grid tile doubles as the custom-emoji sink. An AppKit field (not a
    // SwiftUI `.focused()` one) so we can call `makeFirstResponder` explicitly
    // right before opening the emoji viewer — otherwise the viewer inserts the
    // glyph into whatever field already holds first responder (the name field).
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
}

/// One tile in the device icon grid: a colored monogram chip (default), an SF
/// Symbol line glyph, or the "more" affordance that opens the system emoji viewer.
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

/// One swatch in the device color row: a 24pt circle, or a dashed "+" for the
/// automatic (palette-derived) hue. Selected wears a purple outer ring.
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
                ForEach(Array(apps.prefix(3).enumerated()), id: \.offset) { _, a in
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

/// Wavelink-style searchable app picker: real icons, live filter, tap to route
/// (moves the app into this device). Stays open so several apps can be added.
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

/// Holds the AppKit text field behind the identity tile and force-focuses it
/// before opening the system emoji viewer, so the picked glyph is inserted here
/// rather than into whatever SwiftUI field happens to hold first responder.
@MainActor
final class EmojiCatcher: ObservableObject {
    fileprivate weak var field: NSTextField?

    func openPicker() {
        guard let field, let win = field.window else { return }
        win.makeFirstResponder(field)
        // Open on the next runloop so first-responder is settled first.
        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
    }
}

/// Invisible AppKit text field that receives the glyph chosen in the emoji
/// viewer and reports just the last grapheme (or nil if cleared).
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
            tf.stringValue = picked ?? ""   // keep only the newest glyph
            onPick(picked)
        }
    }
}
