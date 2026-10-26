import AppKit
import SwiftUI

struct KeyboardLayout: Decodable, Identifiable {
  struct Key: Decodable, Identifiable {
    let id: String
    let label: String
    let x, y, w, h: Double
    let kind: String
    let symbol: String?
  }
  struct Light: Decodable, Identifiable {
    let id, zone: String
    let x, y, w, h: Double
  }
  let schema_version: Int
  let id, name: String
  let preview_only: Bool
  let width, height: Double
  let keys: [Key]
  let lights: [Light]

  func validate() throws {
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Bool {
      [x, y, w, h].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= width
        && y + h <= height
    }
    guard schema_version == 1, !id.isEmpty, !name.isEmpty,
      width.isFinite, height.isFinite, width > 0, width <= 50, height > 0, height <= 20,
      !keys.isEmpty, keys.count <= 128, lights.count <= 8,
      Set(keys.map(\.id)).count == keys.count, Set(lights.map(\.id)).count == lights.count,
      keys.allSatisfy({
        !$0.id.isEmpty && $0.label.count <= 16 && ["key", "knob"].contains($0.kind)
          && rect($0.x, $0.y, $0.w, $0.h)
      }),
      lights.allSatisfy({ !$0.id.isEmpty && $0.zone == "side" && rect($0.x, $0.y, $0.w, $0.h) })
    else {
      throw NSError(
        domain: "Keyflux", code: 1, userInfo: [NSLocalizedDescriptionKey: "键盘预览布局无效：\(id)"])
    }
    for (i, a) in keys.enumerated() {
      for b in keys.dropFirst(i + 1)
      where a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h {
        throw NSError(
          domain: "Keyflux", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "键帽重叠：\(a.id) / \(b.id)"])
      }
    }
  }

  static func load() throws -> [KeyboardLayout] {
    #if SWIFT_PACKAGE
      let resources = Bundle.module.resourceURL
    #else
      let resources = Bundle.main.resourceURL
    #endif
    guard let directory = resources?.appendingPathComponent("Keyboards") else { return [] }
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
    let layouts = try urls.map { url in
      let data = try Data(contentsOf: url)
      guard data.count <= 131072 else { throw CocoaError(.fileReadTooLarge) }
      let layout = try JSONDecoder().decode(KeyboardLayout.self, from: data)
      try layout.validate()
      return layout
    }
    guard Set(layouts.map(\.id)).count == layouts.count else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return layouts.sorted {
      ($0.preview_only ? 1 : 0, $0.name) < ($1.preview_only ? 1 : 0, $1.name)
    }
  }
}

enum LightingZone: String, CaseIterable, Identifiable {
  case main, side
  var id: String { rawValue }
  var title: String { self == .main ? "主键区" : "侧边灯条" }
}

struct KeyboardPreview: View {
  let layout: KeyboardLayout
  let main: SignalStyle
  let side: SignalStyle?
  @Binding var zone: LightingZone

  var body: some View {
    GeometryReader { geometry in
      let unit = min(geometry.size.width / layout.width, geometry.size.height / layout.height)
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: unit * 0.62)
          .fill(Color(nsColor: .controlBackgroundColor))
          .overlay(
            RoundedRectangle(cornerRadius: unit * 0.62).stroke(
              Color.primary.opacity(0.22), lineWidth: 1.3))
        RoundedRectangle(cornerRadius: unit * 0.5)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
          .padding(unit * 0.23)
        ForEach(layout.keys) { key in
          ZStack {
            if key.kind == "knob" {
              Circle().fill(Color(nsColor: .windowBackgroundColor))
                .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 1.3))
              Image(systemName: "plus").font(.system(size: unit * 0.4, weight: .light))
                .foregroundStyle(.secondary)
            } else {
              RoundedRectangle(cornerRadius: unit * 0.075)
                .stroke(Color.primary.opacity(0.32), lineWidth: 0.75)
              RoundedRectangle(cornerRadius: unit * 0.2)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                  RoundedRectangle(cornerRadius: unit * 0.2).fill(
                    main.color.opacity(main.brightness / 100 * 0.4))
                )
                .overlay(
                  RoundedRectangle(cornerRadius: unit * 0.2).stroke(
                    main.brightness > 0
                      ? main.color.opacity(main.brightness / 100 * 0.65 + 0.2)
                      : Color.primary.opacity(0.2), lineWidth: 0.85)
                )
                .padding(unit * 0.055)
              if let symbol = key.symbol {
                Image(systemName: symbol).font(.system(size: unit * 0.28, weight: .medium))
                  .foregroundStyle(.primary)
              } else {
                Text(key.label).font(
                  .system(
                    size: max(8, unit * (key.label.count > 4 ? 0.19 : 0.25)), weight: .semibold)
                )
                .multilineTextAlignment(.center).foregroundStyle(.primary)
              }
            }
          }
          .frame(width: key.w * unit, height: key.h * unit)
          .position(x: (key.x + key.w / 2) * unit, y: (key.y + key.h / 2) * unit)
          .onTapGesture { zone = .main }
        }
        ForEach(layout.lights) { light in
          Capsule().fill(
            side.map { $0.color.opacity($0.brightness / 100) } ?? Color.primary.opacity(0.12)
          )
          .frame(width: light.w * unit, height: light.h * unit)
          .contentShape(Rectangle().inset(by: -8))
          .position(x: (light.x + light.w / 2) * unit, y: (light.y + light.h / 2) * unit)
          .onTapGesture { zone = .side }
        }
      }
      .frame(width: layout.width * unit, height: layout.height * unit)
      .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(layout.name)，\(main.title)配色预览；主键区 \(main.hex)，侧灯 \(side?.hex ?? "保持原灯效")")
  }
}
