import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SignalStyle: Identifiable, Equatable {
  let id: String
  let title: String
  var hex: String
  var brightness: Double
  var valid: Bool {
    hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil && brightness.isFinite
      && (0...100).contains(brightness)
  }
  var color: Color {
    get { Color(hex: hex) }
    set { hex = newValue.hex }
  }
  static var defaults: [SignalStyle] {
    zip(
      ["working", "thinking", "output", "tool", "attention", "complete", "error"],
      ["#3B82F6", "#06B6D4", "#8B5CF6", "#3B82F6", "#F97316", "#22C55E", "#EF4444"]
    )
    .map { .init(id: $0.0, title: Model.labels[$0.0]!, hex: $0.1, brightness: 50) }
  }
}

@MainActor
final class Model: ObservableObject {
  @Published var phase = "未连接"
  @Published var backend = "核心未运行"
  @Published var message = ""
  @Published var running = false
  @Published var simulated = false
  @Published var supportsThemeV2 = false
  @Published var busy = false
  @Published var name = "Keyflux"
  @Published var completionSeconds = 5.0
  @Published var signals = SignalStyle.defaults
  @Published var sideSignals = SignalStyle.defaults
  @Published var sideEnabled = false
  @Published var sideMode = "follow_main"
  @Published var previewPhase = "@live"
  @Published var livePhase = "idle"
  @Published var keyboardID =
    UserDefaults.standard.string(forKey: "previewKeyboard") ?? "nuphy-kick75-io"
  @Published var previewZone: LightingZone = .main
  let layouts: [KeyboardLayout]
  let executable: URL
  let stateDirectory: String?
  let snapshotMode: Bool
  private var saved: Data?
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
    snapshotMode = args.contains("--snapshot")
    do { layouts = try KeyboardLayout.load() } catch {
      layouts = []
      message = error.localizedDescription
    }
    if snapshotMode {
      previewPhase = "thinking"
      sideEnabled = true
      sideMode = "independent"
      sideSignals[1].hex = "#C084FC"
    }
  }
  var valid: Bool {
    !name.isEmpty && name.utf8.count <= 64 && signals.allSatisfy(\.valid)
      && sideSignals.allSatisfy(\.valid) && (1...60).contains(completionSeconds)
  }
  var hasChanges: Bool { (try? themeData()) != saved }
  var canUndo: Bool { saved != nil && hasChanges }
  var selectedPhase: String { previewPhase == "@live" ? livePhase : previewPhase }
  var mainPreview: SignalStyle {
    signals.first { $0.id == selectedPhase }
      ?? .init(
        id: selectedPhase, title: Self.labels[selectedPhase] ?? "状态不可用", hex: "#87909C",
        brightness: 0)
  }
  var sidePreview: SignalStyle? {
    guard sideEnabled, !["idle", "unknown"].contains(selectedPhase) else { return nil }
    return sideMode == "follow_main" ? mainPreview : sideSignals.first { $0.id == selectedPhase }
  }
  private var instanceArguments: [String] { stateDirectory.map { ["--state-dir", $0] } ?? [] }
  private func callCore(_ args: [String], input: Data? = nil) async throws -> Data {
    try await Self.invoke(executable, args + instanceArguments, input: input)
  }
  // Pipe/process work runs outside the main actor; every invocation has a
  // timeout so an unavailable core cannot freeze the menu bar.
  nonisolated static func invoke(_ executable: URL, _ args: [String], input: Data? = nil)
    async throws -> Data
  {
    try await Task.detached {
      let process = Process()
      process.executableURL = executable
      process.arguments = args
      let output = Pipe()
      let errors = Pipe()
      let stdin = Pipe()
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
        throw NSError(
          domain: "Keyflux", code: Int(process.terminationStatus),
          userInfo: [NSLocalizedDescriptionKey: String(data: bytes, encoding: .utf8) ?? "核心不可用"])
      }
      return bytes
    }.value
  }

  func refresh() async {
    guard !snapshotMode else { return }
    do {
      let data = try await callCore(["status"])
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let result = root["result"] as? [String: Any],
        let state = result["state"] as? [String: Any]
      else { throw CocoaError(.coderReadCorrupt) }
      running = true
      simulated = result["backend"] as? String == "simulated"
      supportsThemeV2 = (result["theme_schema_versions"] as? [Int])?.contains(2) == true
      livePhase = state["phase"] as? String ?? "unknown"
      phase = Self.labels[livePhase] ?? "状态不可用"
      backend = simulated ? "模拟设备" : "只读核心"
      if let error = result["device_error"] as? String { message = error }
    } catch {
      running = false
      simulated = false
      livePhase = "unknown"
      phase = "未连接"
      backend = "核心未运行"
    }
  }
  func connect() async {
    guard !snapshotMode else { return }
    await refresh()
    if running { await loadTheme() } else { await start(simulate: false) }
  }
  func start(simulate: Bool, load: Bool = true) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    await refresh()
    guard !running else {
      message = "请先停止现有核心，再切换运行模式。"
      return
    }
    do {
      let process = Process()
      process.executableURL = executable
      process.arguments = (simulate ? ["serve", "--simulate"] : ["serve"]) + instanceArguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      daemon = process
      for _ in 0..<15 {
        try await Task.sleep(for: .milliseconds(100))
        await refresh()
        if running {
          if load { await loadTheme() }
          return
        }
      }
      message = "核心启动失败，请检查可执行文件与数据目录。"
    } catch { message = error.localizedDescription }
  }
  func stop() async {
    do {
      _ = try await callCore(["stop"])
      message = ""
    } catch { message = error.localizedDescription }
    await refresh()
  }
  func loadTheme() async {
    do {
      let data = try await callCore(["theme-get"])
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let theme = root["theme"] as? [String: Any]
      else { throw CocoaError(.coderReadCorrupt) }
      try applyTheme(theme)
      saved = try themeData()
    } catch { message = error.localizedDescription }
  }
  private func applyTheme(_ theme: [String: Any]) throws {
    guard let version = theme["schema_version"] as? Int, [1, 2].contains(version) else {
      throw CocoaError(.coderReadCorrupt)
    }
    func styles(_ raw: Any?) -> [SignalStyle] {
      let values = raw as? [String: [String: Any]] ?? [:]
      return SignalStyle.defaults.map { original in
        var style = original
        if let v = values[original.id] {
          style.hex = v["color"] as? String ?? original.hex
          style.brightness = v["brightness"] as? Double ?? original.brightness
        }
        return style
      }
    }
    signals = styles(theme["signals"])
    name = theme["name"] as? String ?? "Keyflux"
    completionSeconds = (theme["completion_hold_ms"] as? Double ?? 5000) / 1000
    let side = theme["side"] as? [String: Any]
    sideEnabled = side?["enabled"] as? Bool ?? false
    sideMode = side?["mode"] as? String ?? "follow_main"
    sideSignals = styles(side?["signals"])
  }
  private func themeData() throws -> Data {
    guard valid else {
      throw NSError(
        domain: "Keyflux", code: 1, userInfo: [NSLocalizedDescriptionKey: "检查主题名称、#RRGGBB 颜色和亮度。"])
    }
    func values(_ styles: [SignalStyle]) -> [String: Any] {
      Dictionary(
        uniqueKeysWithValues: styles.map {
          (
            $0.id,
            ["color": $0.hex.uppercased(), "brightness": Int($0.brightness)] as [String: Any]
          )
        })
    }
    return try JSONSerialization.data(
      withJSONObject: [
        "schema_version": 2, "name": name,
        "completion_hold_ms": Int((completionSeconds * 1000).rounded()),
        "signals": values(signals),
        "side": ["enabled": sideEnabled, "mode": sideMode, "signals": values(sideSignals)],
      ], options: [.sortedKeys, .prettyPrinted])
  }
  func save() async {
    guard !busy else { return }
    do {
      let data = try themeData()
      if !running { await start(simulate: false, load: false) }
      guard running else { return }
      guard supportsThemeV2 else {
        message = "核心版本较旧，请通过电源菜单停止并重新启动核心，再保存新版主题。"
        return
      }
      busy = true
      defer { busy = false }
      _ = try await callCore(["theme-set"], input: data)
      saved = data
      message = "已保存。侧灯方案仅用于屏幕预览，尚未写入键盘。"
    } catch { message = error.localizedDescription }
  }
  func undo() {
    guard let saved else { return }
    do {
      guard let theme = try JSONSerialization.jsonObject(with: saved) as? [String: Any] else {
        return
      }
      try applyTheme(theme)
      message = "已撤销未保存修改"
    } catch { message = error.localizedDescription }
  }
  func preset(_ cold: Bool) {
    signals = SignalStyle.defaults
    if cold {
      let colors = ["#38BDF8", "#22D3EE", "#A78BFA", "#60A5FA", "#FBBF24", "#34D399", "#FB7185"]
      for i in signals.indices { signals[i].hex = colors[i] }
    }
    name = cold ? "Ice" : "Keyflux"
    message = "预设已载入，保存后生效"
  }
  func previewInCore() async {
    guard simulated, running, signals.contains(where: { $0.id == selectedPhase }) else {
      message = "顶部预览实时更新；核心灯光预览需要模拟设备。"
      return
    }
    do {
      let signal = mainPreview
      let draft = try JSONSerialization.data(withJSONObject: [
        "color": signal.hex, "brightness": Int(signal.brightness),
      ])
      _ = try await callCore(["preview", signal.id, "--signal-stdin"], input: draft)
      message = "模拟主键区预览 3 秒；侧灯仅在顶部预览"
    } catch { message = error.localizedDescription }
  }
  func importTheme() async {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      guard data.count <= 16384 else { throw CocoaError(.fileReadTooLarge) }
      _ = try await callCore(["validate-theme"], input: data)
      guard let theme = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.coderReadCorrupt)
      }
      try applyTheme(theme)
      message = "已导入草稿，保存后生效"
    } catch { message = error.localizedDescription }
  }
  func exportTheme() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "keyflux-theme.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try themeData().write(to: url, options: .atomic)
      message = "已导出 Theme v2"
    } catch { message = error.localizedDescription }
  }
  nonisolated static let labels = [
    "idle": "空闲", "working": "工作中", "thinking": "Thinking", "output": "输出中", "tool": "工具执行",
    "attention": "待处理", "complete": "本轮结束", "error": "错误", "unknown": "状态不可用",
  ]
}

extension Color {
  init(hex: String) {
    guard hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
      let value = UInt64(hex.dropFirst(), radix: 16)
    else {
      self = .gray
      return
    }
    self.init(
      .sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
      blue: Double(value & 255) / 255, opacity: 1)
  }
  var hex: String {
    let rgb = NSColor(self).usingColorSpace(.sRGB) ?? .black
    func byte(_ component: CGFloat) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
    return String(
      format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent),
      byte(rgb.blueComponent))
  }
}

struct SettingsView: View {
  @ObservedObject var model: Model
  private var layout: KeyboardLayout? {
    model.layouts.first { $0.id == model.keyboardID } ?? model.layouts.first
  }
  private var styles: Binding<[SignalStyle]> {
    model.previewZone == .main ? $model.signals : $model.sideSignals
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text("Keyflux").font(.system(size: 28, weight: .semibold))
          Spacer()
          Text("\(model.backend) · \(model.phase)").font(.callout).foregroundStyle(.secondary)
          Menu {
            Button("启动只读核心") {
              Task { await model.start(simulate: false, load: !model.hasChanges) }
            }.disabled(model.running)
            Button("启动模拟设备") { Task { await model.start(simulate: true, load: !model.hasChanges) } }
              .disabled(model.running)
            Button("停止核心") { Task { await model.stop() } }.disabled(!model.running)
          } label: {
            Image(systemName: "power")
          }.menuStyle(.borderlessButton).frame(width: 25)
        }
        HStack {
          Picker("键盘", selection: $model.keyboardID) {
            ForEach(model.layouts) { item in
              Text(item.name + (item.preview_only ? " · 布局示例" : "")).tag(item.id)
            }
          }.frame(width: 270)
          Spacer()
          Picker("预览状态", selection: $model.previewPhase) {
            Text("跟随核心状态").tag("@live")
            ForEach(model.signals) { signal in Text(signal.title).tag(signal.id) }
          }.frame(width: 240)
        }
        if let layout {
          KeyboardPreview(
            layout: layout, main: model.mainPreview, side: model.sidePreview,
            zone: $model.previewZone
          )
          .frame(height: 285)
        } else {
          Text("未找到有效的键盘预览布局").frame(height: 285)
        }
      }.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Picker("灯区", selection: $model.previewZone) {
              ForEach(LightingZone.allCases) { item in Text(item.title).tag(item) }
            }.pickerStyle(.segmented).frame(width: 260)
            Spacer()
            if model.previewZone == .main {
              Menu("主键区预设") {
                Button("Keyflux") { model.preset(false) }
                Button("冰蓝") { model.preset(true) }
              }.frame(width: 130)
            } else {
              Button("复制主键区配色") { model.sideSignals = model.signals }
                .disabled(!model.sideEnabled || model.sideMode != "independent")
            }
          }
          if model.previewZone == .side {
            HStack {
              Toggle("保存侧灯方案", isOn: $model.sideEnabled).toggleStyle(.switch)
              Spacer()
              Picker("配色", selection: $model.sideMode) {
                Text("跟随主键区").tag("follow_main")
                Text("独立配色").tag("independent")
              }.frame(width: 260).disabled(!model.sideEnabled)
            }
            Text("侧灯硬件控制尚未开放；当前仅保存配色与屏幕预览。")
              .font(.callout).foregroundStyle(.secondary)
          }
          VStack(spacing: 8) {
            ForEach(styles) { $signal in
              SignalRow(signal: $signal, selected: model.selectedPhase == signal.id) {
                model.previewPhase = signal.id
              }
            }
          }.disabled(
            model.previewZone == .side && (!model.sideEnabled || model.sideMode == "follow_main"))
          HStack {
            TextField("主题名称", text: $model.name).textFieldStyle(.roundedBorder).frame(width: 190)
            Spacer()
            Stepper(
              "完成保持 \(model.completionSeconds.formatted(.number.precision(.fractionLength(0...3)))) 秒",
              value: $model.completionSeconds, in: 1...60
            ).frame(width: 200)
          }
        }.padding(.horizontal, 28).padding(.vertical, 18)
      }.disabled(model.busy)
      Divider()
      HStack(spacing: 12) {
        Button("导入…") { Task { await model.importTheme() } }
        Button("导出…") { model.exportTheme() }.disabled(!model.valid)
        Button("模拟预览") { Task { await model.previewInCore() } }.disabled(
          !model.simulated || !model.valid
            || !model.signals.contains(where: { $0.id == model.selectedPhase }))
        Spacer()
        if model.hasChanges { Text("未保存").font(.callout).foregroundStyle(.secondary) }
        Button("撤销修改") { model.undo() }.disabled(!model.canUndo)
        Button("保存") { Task { await model.save() } }.keyboardShortcut("s").buttonStyle(
          .borderedProminent
        )
        .disabled(!model.valid || !model.hasChanges)
      }.padding(.horizontal, 28).padding(.vertical, 14).disabled(model.busy)
      if !model.valid || !model.message.isEmpty {
        Text(model.valid ? model.message : "请检查颜色格式（#RRGGBB）和主题名称。").font(.callout).foregroundStyle(
          .secondary
        ).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(
            .bottom, 12)
      }
    }
    .frame(minWidth: 860, idealWidth: 1000, minHeight: 720, idealHeight: 900)
    .background(Color(nsColor: .windowBackgroundColor))
    .onChange(of: model.keyboardID) { id in
      if !model.snapshotMode { UserDefaults.standard.set(id, forKey: "previewKeyboard") }
    }
    .task { await model.connect() }
  }
}

struct SignalRow: View {
  @Binding var signal: SignalStyle
  let selected: Bool
  let select: () -> Void
  var body: some View {
    HStack(spacing: 18) {
      Button(action: select) {
        HStack(spacing: 9) {
          Image(systemName: selected ? "circle.inset.filled" : "circle").foregroundStyle(
            selected ? Color.accentColor : .secondary)
          Text(signal.title).foregroundStyle(.primary)
        }.frame(width: 122, alignment: .leading)
      }.buttonStyle(.plain).accessibilityLabel("预览\(signal.title)")
      ColorPicker(
        "\(signal.title)颜色",
        selection: Binding(
          get: { signal.color },
          set: {
            signal.color = $0
            select()
          }), supportsOpacity: false
      )
      .labelsHidden()
      TextField(
        "#RRGGBB",
        text: Binding(
          get: { signal.hex },
          set: {
            signal.hex = $0
            select()
          })
      ).font(.system(.body, design: .monospaced))
        .textFieldStyle(.roundedBorder).frame(width: 112)
        .foregroundStyle(signal.valid ? Color.primary : .red)
        .accessibilityLabel("\(signal.title)十六进制颜色")
      Slider(
        value: Binding(
          get: { signal.brightness },
          set: {
            signal.brightness = $0
            select()
          }), in: 0...100, step: 1
      ).accessibilityLabel(
        "\(signal.title)亮度")
      Text("\(Int(signal.brightness))%").monospacedDigit().frame(width: 42, alignment: .trailing)
    }.padding(.horizontal, 10).padding(.vertical, 4)
      .background(
        selected ? Color.accentColor.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 5))
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
    statusItem.button?.image = NSImage(
      systemSymbolName: "waveform.path", accessibilityDescription: "Keyflux")
    let menu = NSMenu()
    menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target =
      self
    menu.addItem(.separator())
    menu.addItem(withTitle: "退出 Keyflux", action: #selector(quit), keyEquivalent: "q").target = self
    statusItem.menu = menu
    if CommandLine.arguments.contains("--snapshot-side") { model.previewZone = .side }
    if CommandLine.arguments.contains("--snapshot-air") { model.keyboardID = "nuphy-air75-v3" }
    if CommandLine.arguments.contains("--snapshot-light") {
      NSApp.appearance = NSAppearance(named: .aqua)
    }
    showSettings()
    if model.snapshotMode {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
          i + 1 < CommandLine.arguments.count,
          let view = window?.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
          NSApp.terminate(nil)
          return
        }
        let target = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window!.windowNumber), target.path]
        do {
          try capture.run()
          capture.waitUntilExit()
        } catch {}
        if !FileManager.default.fileExists(atPath: target.path) {
          view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
          }
          if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: target)
          }
        }
        NSApp.terminate(nil)
      }
    }
  }
  @objc func showSettings() {
    if window == nil {
      let created = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      created.title =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Keyflux"
      created.minSize = NSSize(width: 860, height: 740)
      created.isReleasedWhenClosed = false
      created.delegate = self
      created.contentView = NSHostingView(rootView: SettingsView(model: model))
      created.center()
      window = created
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if !model.snapshotMode { Task { await model.refresh() } }
  }
  func windowDidBecomeKey(_ notification: Notification) {
    guard refreshTimer == nil, !model.snapshotMode else { return }
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.model.refresh() }
    }
  }
  func windowWillClose(_ notification: Notification) {
    refreshTimer?.invalidate()
    refreshTimer = nil
  }
  func windowDidMiniaturize(_ notification: Notification) {
    refreshTimer?.invalidate()
    refreshTimer = nil
  }
  @objc func quit() { NSApp.terminate(nil) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
