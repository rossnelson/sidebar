import AppKit
import SidebarCore
import SwiftUI

/// Colors for the sidebar and the palette. With Chrome's default theme
/// (no seed color), the views keep the system sidebar material.
struct SidebarColors: Equatable {
  var background: Color?
  var hover: Color
  var selected: Color
  var text: Color?

  static let system = SidebarColors(
    background: nil, hover: Color.primary.opacity(0.08), selected: Color.accentColor.opacity(0.35), text: nil)

  init(background: Color?, hover: Color, selected: Color, text: Color?) {
    self.background = background
    self.hover = hover
    self.selected = selected
    self.text = text
  }

  init(theme: ProfileTheme, colorScheme: ColorScheme) {
    guard let seed = theme.seed else {
      self = .system
      return
    }
    let palette = ThemePalette.make(seed: seed, dark: colorScheme == .dark, grayscale: theme.grayscale)
    self.init(
      background: Color(palette.background), hover: Color(palette.hover),
      selected: Color(palette.selected), text: Color(palette.text))
  }
}

extension ProfileTheme {
  /// The appearance to force on our panels, or `nil` to follow the system.
  var appearance: NSAppearance? {
    switch scheme {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

extension Color {
  init(_ rgb: RGB) {
    self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
  }
}

private struct SidebarColorsKey: EnvironmentKey {
  static let defaultValue = SidebarColors.system
}

extension EnvironmentValues {
  var sidebarColors: SidebarColors {
    get { self[SidebarColorsKey.self] }
    set { self[SidebarColorsKey.self] = newValue }
  }
}

/// Applies the profile's colors to a whole panel: background, text and the
/// environment that rows read.
struct Themed: ViewModifier {
  let theme: ProfileTheme
  var cornerRadius: CGFloat = 10
  /// Fill the background with the profile's color. Off for glass panels.
  var fillsBackground = true
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let colors = SidebarColors(theme: theme, colorScheme: colorScheme)
    content
      .foregroundStyle(colors.text.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
      .environment(\.sidebarColors, colors)
      .background {
        if fillsBackground, let background = colors.background {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(background)
        }
      }
  }
}

/// A row's hover and selected backgrounds, in the profile's colors.
struct RowStyle: ViewModifier {
  let highlighted: Bool
  let hovering: Bool
  var cornerRadius: CGFloat = 6
  @Environment(\.sidebarColors) private var colors

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(highlighted ? colors.selected : hovering ? colors.hover : .clear))
  }
}
