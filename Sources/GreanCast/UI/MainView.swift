// MainView.swift
// Main window: the iPhone screen (or the current setup/progress state), a toolbar with the
// hardware buttons, and an inspector with status, quick actions and the log.

import SwiftUI

struct MainView: View {
    @ObservedObject var session: DeviceSession
    @AppStorage("showInspector") private var showInspector = false

    var body: some View {
        content
            .frame(minWidth: 360, minHeight: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar { toolbar }
            .inspector(isPresented: $showInspector) {
                InspectorView(session: session)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .connected:
            ZStack {
                MirrorView(image: session.image, handler: session)
                if session.isLocked { LockOverlay(session: session) }
            }
        case .needsSetup:
            SetupView(session: session)
        case .checking:
            ProgressState(title: "Checking prerequisites…", detail: nil)
        case .preparing(let text):
            ProgressState(title: text, detail: "This happens once per developer team.")
        case .launching:
            ProgressState(title: "Starting WebDriverAgent on the iPhone…",
                          detail: session.hint ?? "Keep the iPhone unlocked. The first launch can take a minute.")
        case .connecting:
            ProgressState(title: "Connecting…", detail: nil)
        case .waitingForUnlock:
            VStack(spacing: 14) {
                Image(systemName: "lock.iphone").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Unlock your iPhone").font(.title3.bold())
                Text("GreanCast will connect as soon as it is unlocked. WebDriverAgent can't type your passcode.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Wake & Unlock (no passcode)") { session.wakeAndUnlock() }
            }
            .padding(40)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            FailedState(message: message, session: session)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            StatusPill(session: session)
        }
        ToolbarItemGroup {
            Group {
                Button { session.home() } label: { Label("Home", systemImage: "house") }
                    .help("Home (⇧⌘H)")
                Button { session.appSwitcher() } label: { Label("App Switcher", systemImage: "square.stack") }
                    .help("App Switcher")
                Button { session.controlCenter() } label: { Label("Control Center", systemImage: "switch.2") }
                    .help("Control Center")
                Button { session.volume(up: false) } label: { Label("Volume Down", systemImage: "speaker.minus") }
                Button { session.volume(up: true) } label: { Label("Volume Up", systemImage: "speaker.plus") }
                Button { session.copyScreenshot() } label: { Label("Copy Screenshot", systemImage: "camera") }
                    .help("Copy a screenshot to the clipboard (⇧⌘C)")
            }
            .disabled(session.phase != .connected)
            Toggle(isOn: $session.keepAwake) {
                Label("Keep Awake", systemImage: session.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
            }
            .help(session.keepAwake ? "Keeping the iPhone awake while connected (click to turn off)"
                                    : "Keep the iPhone awake while connected")
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
    }
}

// MARK: - Pieces

private struct StatusPill: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var color: Color {
        switch session.phase {
        case .connected: return session.isLocked ? .orange : .green
        case .failed: return .red
        case .needsSetup: return .orange
        default: return .yellow
        }
    }

    private var text: String {
        switch session.phase {
        case .connected:
            let name = session.selectedPhone?.name ?? "iPhone"
            return session.isLocked ? "\(name) · locked" : "\(name) · \(session.transportLabel)"
        case .needsSetup: return "Setup needed"
        case .failed: return "Not connected"
        default: return "Connecting…"
        }
    }
}

private struct ProgressState: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(title).font(.title3).multilineTextAlignment(.center)
            if let detail { Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailedState: View {
    let message: String
    @ObservedObject var session: DeviceSession

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
            Text("Couldn't connect to the iPhone").font(.title3.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            HStack {
                Button("Try Again") { session.start() }.keyboardShortcut(.defaultAction)
                SettingsLink { Text("Settings…") }
            }
        }
        .padding(40)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LockOverlay: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 34))
            Text("The iPhone is locked").font(.title3.bold())
            Text("Unlock it on the device. WebDriverAgent can't type a passcode, but it can wake and unlock an iPhone that has none.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Wake & Unlock") { session.unlock() }
        }
        .padding(28)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Inspector

private struct InspectorView: View {
    @ObservedObject var session: DeviceSession
    @ObservedObject var log = Log.shared
    @State private var bundleID = "com.apple.mobilenotes"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Status") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow { Text("Transport").foregroundStyle(.secondary); Text(session.transportLabel) }
                    GridRow { Text("Screen").foregroundStyle(.secondary); Text("\(Int(session.deviceSize.width))×\(Int(session.deviceSize.height)) pt") }
                    GridRow { Text("Video").foregroundStyle(.secondary); Text("\(session.fps) fps") }
                    GridRow { Text("Last command").foregroundStyle(.secondary); Text(session.lastLatencyMS.map { "\($0) ms" } ?? "—") }
                    GridRow { Text("Queued").foregroundStyle(.secondary); Text("\(session.pending)") }
                    GridRow { Text("Keep awake").foregroundStyle(.secondary); Text(session.keepAwake ? "On" : "Off") }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Open an app") {
                HStack {
                    TextField("Bundle ID", text: $bundleID).textFieldStyle(.roundedBorder)
                    Button("Open") { session.launchApp(bundleID) }
                }
                .disabled(session.phase != .connected)
            }

            GroupBox("Video quality") {
                HStack {
                    Slider(value: $session.videoScale, in: 25...100, step: 25) { editing in
                        if !editing { session.applyVideoScale() }
                    }
                    Text("\(Int(session.videoScale)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }

            Text("Log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.entries) { e in
                            Text("\(log.timestamp(e))  \(e.text)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(e.isError ? Color.red : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(e.id)
                        }
                    }
                    .textSelection(.enabled)
                }
                .onChange(of: log.entries.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .padding(12)
    }
}
