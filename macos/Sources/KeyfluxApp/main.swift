import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SignalStyle: Identifiable {
    let id: String
    let title: String
    var color: Color
    var brightness: Double
}

@MainActor
final class Model: ObservableObject {
    @Published var phase = "未连接"
    @Published var backend = "核心未运行"
    @Published var message = ""
    @Published var running = false
    @Published var busy = false
    @Published var completionSeconds = 5.0
    @Published var signals: [SignalStyle] = [
        .init(id: "working", title: "工作中", color: Color(hex: "3B82F6"), brightness: 50),
        .init(id: "thinking", title: "Thinking", color: Color(hex: "06B6D4"), brightness: 50),
        .init(id: "output", title: "输出中", color: Color(hex: "8B5CF6"), brightness: 50),
        .init(id: "tool", title: "工具执行", color: Color(hex: "3B82F6"), brightness: 50),
        .init(id: "attention", title: "待处理", color: Color(hex: "F97316"), brightness: 50),
        .init(id: "complete", title: "本轮结束", color: Color(hex: "22C55E"), brightness: 50),
        .init(id: "error", title: "错误", color: Color(hex: "EF4444"), brightness: 50),
    ]
    let executable: URL
    let stateDirectory: String?
    private var daemon: Process?

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--core"), i + 1 < args.count {
            executable = URL(fileURLWithPath: args[i + 1])
        } else {
            executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/keyflux")
        }
        if let i = args.firstIndex(of: "--state-dir"), i + 1 < args.count {
            stateDirectory = args[i + 1]
        } else {
            stateDirectory = nil
        }
    }

    private var instanceArguments: [String] {
        stateDirectory.map { ["--state-dir", $0] } ?? []
    }

    private func callCore(_ args: [String], input: Data? = nil) async throws -> Data {
        try await Self.invoke(executable, args + instanceArguments, input: input)
    }

    // Pipe/process work runs outside the main actor; every invocation has a
    // timeout so an unavailable core cannot freeze the menu bar.
    nonisolated static func invoke(_ executable: URL, _ args: [String], input: Data? = nil) async throws -> Data {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            let output = Pipe(), errors = Pipe(), stdin = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = stdin
            try process.run()
            if let input { stdin.fileHandleForWriting.write(input) }
            try? stdin.fileHandleForWriting.close()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "Keyflux", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(data: bytes, encoding: .utf8) ?? "核心不可用"])
            }
            return bytes
        }.value
    }

    func refresh() async {
        do {
            let data = try await callCore(["status"])
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = root["result"] as? [String: Any],
                  let state = result["state"] as? [String: Any] else { return }
            running = true
            phase = Self.labels[state["phase"] as? String ?? "unknown"] ?? "状态不可用"
            backend = result["backend"] as? String == "simulated" ? "模拟设备 · 实体灯光请使用硬件测试脚本" : "只读模式 · 实体灯光请使用硬件测试脚本"
            if let error = result["device_error"] as? String { message = error }
        } catch {
            running = false; phase = "未连接"; backend = "核心未运行"
        }
    }

    func start(simulate: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await refresh()
        guard !running else { message = "请先停止现有核心，再切换运行模式。"; return }
        do {
            let process = Process()
            process.executableURL = executable
            process.arguments = (simulate ? ["serve", "--simulate"] : ["serve"]) + instanceArguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            daemon = process
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                await refresh()
                if running { await loadTheme(); message = ""; break }
            }
            if !running { message = "核心启动失败，请使用终端检查 keyflux serve。" }
        } catch { message = error.localizedDescription }
    }

    func stop() async {
        do { _ = try await callCore(["stop"]); message = "" }
        catch { message = error.localizedDescription }
        await refresh()
    }
    func loadTheme() async {
        do {
            let data = try await callCore(["theme-get"])
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let theme = root?["theme"] as? [String: Any] { applyTheme(theme) }
        } catch { message = error.localizedDescription }
    }
    private func applyTheme(_ theme: [String: Any]) {
        guard let values = theme["signals"] as? [String: [String: Any]] else { return }
        for i in signals.indices {
            if let value = values[signals[i].id], let hex = value["color"] as? String, let brightness = value["brightness"] as? Double {
                signals[i].color = Color(hex: hex); signals[i].brightness = brightness
            }
        }
        completionSeconds = (theme["completion_hold_ms"] as? Double ?? 5000) / 1000
    }
    private func themeData() throws -> Data {
        var values: [String: Any] = [:]
        for signal in signals { values[signal.id] = ["color": signal.color.hex, "brightness": Int(signal.brightness)] }
        return try JSONSerialization.data(withJSONObject: ["schema_version": 1, "name": "Keyflux", "completion_hold_ms": Int(completionSeconds * 1000), "signals": values], options: [.sortedKeys, .prettyPrinted])
    }
    func save() async {
        do {
            _ = try await callCore(["theme-set"], input: themeData())
            message = "已保存"
        } catch { message = error.localizedDescription }
    }
    func preview(_ id: String) async {
        do {
            guard let signal = signals.first(where: { $0.id == id }) else { return }
            let draft = try JSONSerialization.data(withJSONObject: ["color": signal.color.hex, "brightness": Int(signal.brightness)])
            _ = try await callCore(["preview", id, "--signal-stdin"], input: draft)
            message = "模拟预览 3 秒"
        }
        catch { message = error.localizedDescription }
        await refresh()
    }
    func importTheme() async {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 16384 else { throw CocoaError(.fileReadTooLarge) }
            _ = try await callCore(["theme-set"], input: data)
            await loadTheme(); message = "已导入并保存"
        } catch { message = error.localizedDescription }
    }
    func exportTheme() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "keyflux-theme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try themeData().write(to: url, options: .atomic); message = "已导出" }
        catch { message = error.localizedDescription }
    }
    static let labels = ["idle": "空闲", "working": "工作中", "thinking": "Thinking", "output": "输出中", "tool": "工具执行", "attention": "待处理", "complete": "本轮结束", "error": "错误", "unknown": "状态不可用"]
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
    var hex: String {
        let rgb = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keyflux").font(.system(size: 30, weight: .semibold))
                Spacer()
                Text(model.phase).foregroundStyle(.secondary)
            }
            Text(model.backend).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("启动只读核心") { Task { await model.start(simulate: false) } }.disabled(model.running || model.busy)
                Button("启动模拟设备") { Task { await model.start(simulate: true) } }.disabled(model.running || model.busy)
                Spacer()
                Button("停止核心") { Task { await model.stop() } }.disabled(!model.running)
            }
            Divider()
            VStack(spacing: 16) {
                ForEach($model.signals) { $signal in
                    HStack(spacing: 18) {
                        Text(signal.title).frame(width: 82, alignment: .leading)
                        ColorPicker("颜色", selection: $signal.color, supportsOpacity: false).labelsHidden()
                        Slider(value: $signal.brightness, in: 0...100, step: 1).accessibilityLabel("\(signal.title)亮度")
                        Text("\(Int(signal.brightness))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                        Button("预览") { Task { await model.preview(signal.id) } }.disabled(!model.running)
                    }
                }
                HStack {
                    Text("完成保持时间")
                    Spacer()
                    Stepper("\(Int(model.completionSeconds)) 秒", value: $model.completionSeconds, in: 1...60)
                        .frame(width: 130)
                }
            }
            Divider()
            HStack {
                Button("导入") { Task { await model.importTheme() } }.disabled(!model.running)
                Button("导出") { model.exportTheme() }
                Spacer()
                Button("重新读取") { Task { await model.loadTheme() } }.disabled(!model.running)
                Button("保存") { Task { await model.save() } }.keyboardShortcut("s").disabled(!model.running)
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(32).frame(width: 580)
        .task { await model.refresh(); if model.running { await model.loadTheme() } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var refreshTimer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Keyflux")
        let menu = NSMenu()
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Keyflux", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        showSettings()
    }
    @objc func showSettings() {
        if window == nil {
            let created = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            created.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Keyflux"
            created.isReleasedWhenClosed = false; created.delegate = self
            created.contentView = NSHostingView(rootView: SettingsView(model: model))
            created.center(); window = created
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        Task { await model.refresh() }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.model.refresh() }
        }
    }
    func windowWillClose(_ notification: Notification) { refreshTimer?.invalidate(); refreshTimer = nil }
    func windowDidMiniaturize(_ notification: Notification) { refreshTimer?.invalidate(); refreshTimer = nil }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
