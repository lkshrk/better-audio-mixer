import BamCore
import SwiftUI

struct ConsoleView: View {
    @Bindable var model: ConsoleViewModel

    private var t: Theme { .make(dark: model.dark) }

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            if model.devices.isEmpty {
                EmptyConsole(model: model)
            } else {
                StripsArea(model: model)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(t.bg.ignoresSafeArea())
        .environment(\.theme, t)
        .focusEffectDisabled()
        .preferredColorScheme(model.dark ? .dark : .light)
        .overlay(alignment: .bottom) {
            if let err = model.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.red.opacity(0.85), in: Capsule())
                    .padding(.bottom, 14)
            }
        }
    }
}

// MARK: - Top bar

/// Slim custom bar drawn into the full-size content area; the macOS traffic
/// lights float over its left inset. Brand left, system-output picker right.
private struct TopBar: View {
    @Environment(\.theme) private var t

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 17, height: 17)
            Text("Better Audio Mixer")
                .font(.system(size: 12, weight: .semibold)).tracking(-0.1)
                .foregroundStyle(t.text)
            Spacer(minLength: 16)
        }
        .padding(.leading, 78)
        .padding(.trailing, 16)
        .frame(height: 38)
        .background(t.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(t.line).frame(height: 1) }
    }
}

// MARK: - Strips area

private struct StripsArea: View {
    @Environment(\.theme) private var t
    @Bindable var model: ConsoleViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(model.devices) { mix in
                        DeviceStrip(model: model, mix: mix)
                    }
                    AddDeviceButton(model: model)
                }
                .padding(.init(top: 14, leading: 16, bottom: 14, trailing: 16))
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MasterStrip(model: model)
                .padding(.vertical, 14)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.panel)
    }
}

private struct AddDeviceButton: View {
    @Environment(\.theme) private var t
    @Bindable var model: ConsoleViewModel

    var body: some View {
        Button { model.addDevice() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                Text("New device").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(t.dim)
            .frame(width: t.stripW)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.001))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(t.line2)))
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .help("Add an empty virtual output device")
    }
}

private struct EmptyConsole: View {
    @Environment(\.theme) private var t
    @Bindable var model: ConsoleViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40)).foregroundStyle(t.faint)
            Text("No devices yet").font(.headline).foregroundStyle(t.dim)
            Button { model.addDevice() } label: {
                Label("Create a Device", systemImage: "plus")
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(t.accent)
            .focusEffectDisabled()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.panel)
    }
}

#Preview {
    let model = ConsoleViewModel(engine: MockAudioEngine())
    let cfg = BamConfig(
        sources: [
            Source(id: "s-game", name: "Game", kind: .app,
                   bundleIDs: ["com.valvesoftware.steam"], hue: 0.0),
            Source(id: "s-chat", name: "Chat", kind: .app,
                   bundleIDs: ["com.hnc.Discord"], hue: 0.66),
            Source(id: "s-music", name: "Music", kind: .app,
                   bundleIDs: ["com.spotify.client", "com.apple.Music"], hue: 0.38)
        ],
        mixes: [
            Mix(id: "m-game", name: "Game", dest: .virtualSlot(0),
                sends: [Send(source: "s-game")], tone: 0.0),
            Mix(id: "m-chat", name: "Chat", dest: .virtualSlot(1),
                sends: [Send(source: "s-chat")], tone: 0.66),
            Mix(id: "m-music", name: "Music", dest: .virtualSlot(2),
                sends: [Send(source: "s-music")], tone: 0.38)
        ]
    )
    return ConsoleView(model: model)
        .frame(width: 760, height: 560)
        .task { await model.startMock(config: cfg) }
}
