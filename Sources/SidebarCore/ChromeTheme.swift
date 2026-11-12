import Foundation

// MARK: - Profiles

/// One entry of `profile.info_cache` in Chrome's `Local State`.
public struct ProfileInfo: Sendable, Equatable {
  /// Folder name under the Chrome data folder, for example `Profile 1`.
  public let directory: String
  public let name: String
  public let isUsingDefaultName: Bool
  public let givenName: String?

  public init(directory: String, name: String, isUsingDefaultName: Bool, givenName: String?) {
    self.directory = directory
    self.name = name
    self.isUsingDefaultName = isUsingDefaultName
    self.givenName = givenName
  }
}

public enum ChromeProfiles {
  public static func parse(localState: Data) -> [ProfileInfo] {
    guard
      let json = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
      let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]
    else { return [] }
    return cache.map { directory, info in
      ProfileInfo(
        directory: directory,
        name: info["name"] as? String ?? directory,
        isUsingDefaultName: info["is_using_default_name"] as? Bool ?? false,
        givenName: info["gaia_given_name"] as? String)
    }
    .sorted { $0.directory < $1.directory }
  }

  /// Finds the profile from a Chrome window's Accessibility title, which ends
  /// with ` - Google Chrome - <person>` or ` - Google Chrome - <person> (<profile>)`.
  /// A profile that still has Chrome's default name shows the person only.
  public static func directory(forWindowTitle title: String, profiles: [ProfileInfo]) -> String? {
    guard let marker = title.range(of: " - Google Chrome - ", options: .backwards) else { return nil }
    let suffix = title[marker.upperBound...].trimmingCharacters(in: .whitespaces)

    if suffix.hasSuffix(")"), let open = suffix.range(of: " (", options: .backwards) {
      let name = String(suffix[open.upperBound..<suffix.index(before: suffix.endIndex)])
      if let match = profiles.first(where: { $0.name == name }) { return match.directory }
    }
    let defaultNamed = profiles.filter(\.isUsingDefaultName)
    if let match = defaultNamed.first(where: { $0.givenName == suffix || $0.name == suffix }) {
      return match.directory
    }
    return defaultNamed.count == 1 ? defaultNamed[0].directory : nil
  }
}

// MARK: - Theme

/// The colors a profile chose in Chrome's "Customize Chrome" panel.
public struct ProfileTheme: Sendable, Equatable {
  public enum Scheme: Int, Sendable { case system = 0, light = 1, dark = 2 }

  /// The seed color as 0xRRGGBB, or `nil` for Chrome's default theme.
  public var seed: UInt32?
  public var scheme: Scheme
  public var grayscale: Bool

  public init(seed: UInt32?, scheme: Scheme = .system, grayscale: Bool = false) {
    self.seed = seed
    self.scheme = scheme
    self.grayscale = grayscale
  }

  public static let standard = ProfileTheme(seed: nil)

  /// Reads `browser.theme` from a profile's `Preferences` file.
  public static func parse(preferences: Data) -> ProfileTheme {
    guard
      let json = try? JSONSerialization.jsonObject(with: preferences) as? [String: Any],
      let theme = (json["browser"] as? [String: Any])?["theme"] as? [String: Any]
    else { return .standard }
    // Chrome stores ARGB as a signed 32-bit integer.
    let seed = (theme["user_color2"] ?? theme["user_color"]) as? Int
    let scheme = (theme["color_scheme2"] ?? theme["color_scheme"]) as? Int ?? 0
    let grayscale = (theme["is_grayscale2"] ?? theme["is_grayscale"]) as? Bool ?? false
    return ProfileTheme(
      seed: seed.map { UInt32(truncatingIfNeeded: $0) & 0xFF_FFFF },
      scheme: Scheme(rawValue: scheme) ?? .system,
      grayscale: grayscale)
  }
}

// MARK: - Palette

public struct RGB: Sendable, Equatable {
  public var r, g, b: Double  // 0...1

  public init(r: Double, g: Double, b: Double) {
    self.r = r
    self.g = g
    self.b = b
  }

  public init(hex: UInt32) {
    self.init(
      r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
  }

  public var hex: UInt32 {
    func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
    return byte(r) << 16 | byte(g) << 8 | byte(b)
  }
}

/// The sidebar's colors, derived from a seed the way Material You derives
/// Chrome's: keep the seed's hue and pick fixed lightness levels (tones).
public struct ThemePalette: Sendable, Equatable {
  public var background: RGB
  public var hover: RGB
  public var selected: RGB
  public var text: RGB
  public var secondaryText: RGB
  public var accent: RGB

  public static func make(seed: UInt32, dark: Bool, grayscale: Bool = false) -> ThemePalette {
    let hue = LCh(rgb: RGB(hex: seed)).h
    let scale = grayscale ? 0.0 : 1.0
    func tone(_ l: Double, _ c: Double) -> RGB { LCh(l: l, c: c * scale, h: hue).rgb }
    return dark
      ? ThemePalette(
        background: tone(14, 14), hover: tone(22, 14), selected: tone(32, 24),
        text: tone(94, 3), secondaryText: tone(72, 6), accent: tone(80, 36))
      : ThemePalette(
        background: tone(94, 8), hover: tone(89, 10), selected: tone(84, 22),
        text: tone(10, 3), secondaryText: tone(42, 6), accent: tone(40, 40))
  }
}

/// CIE LCh(ab), D65. Lightness here is Material's "tone".
public struct LCh: Sendable, Equatable {
  public var l, c, h: Double  // h in degrees

  public init(l: Double, c: Double, h: Double) {
    self.l = l
    self.c = c
    self.h = h
  }

  private static let white = (x: 0.95047, y: 1.0, z: 1.08883)
  private static let epsilon = pow(6.0 / 29.0, 3)

  public init(rgb: RGB) {
    func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    let r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b)
    let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / Self.white.x
    let y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / Self.white.y
    let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / Self.white.z
    func f(_ t: Double) -> Double { t > Self.epsilon ? cbrt(t) : t / (3 * pow(6.0 / 29.0, 2)) + 4.0 / 29.0 }
    let fx = f(x), fy = f(y), fz = f(z)
    let a = 500 * (fx - fy), bb = 200 * (fy - fz)
    let hue = atan2(bb, a) * 180 / .pi
    self.init(l: 116 * fy - 16, c: (a * a + bb * bb).squareRoot(), h: hue < 0 ? hue + 360 : hue)
  }

  /// Converts to sRGB, lowering chroma until the color fits the sRGB gamut.
  public var rgb: RGB {
    var chroma = c
    while true {
      if let rgb = Self.rgb(l: l, c: chroma, h: h) { return rgb }
      chroma -= 0.5
      if chroma <= 0 { return Self.rgb(l: l, c: 0, h: h) ?? RGB(r: 0, g: 0, b: 0) }
    }
  }

  private static func rgb(l: Double, c: Double, h: Double) -> RGB? {
    let radians = h * .pi / 180
    let a = c * cos(radians), b = c * sin(radians)
    let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
    func inverse(_ t: Double) -> Double { t > 6.0 / 29.0 ? t * t * t : 3 * pow(6.0 / 29.0, 2) * (t - 4.0 / 29.0) }
    let x = white.x * inverse(fx), y = white.y * inverse(fy), z = white.z * inverse(fz)
    let lr = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
    let lg = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
    let lb = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
    let tolerance = 0.0005
    guard [lr, lg, lb].allSatisfy({ $0 >= -tolerance && $0 <= 1 + tolerance }) else { return nil }
    func gamma(_ v: Double) -> Double {
      let v = min(max(v, 0), 1)
      return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    return RGB(r: gamma(lr), g: gamma(lg), b: gamma(lb))
  }
}

/// Arc-style space colors: a vivid two-stop gradient around the seed's hue,
/// with white text on top.
public struct SpacePalette: Sendable, Equatable {
  public var gradientStart: RGB
  public var gradientEnd: RGB
  /// A third tone, a little off the seed's hue, that gives the mesh gradient depth.
  public var accent: RGB = RGB(r: 0, g: 0, b: 0)
  /// A dark tone of the hue for text on the white active-tab card.
  public var ink: RGB = RGB(r: 0, g: 0, b: 0)

  public static func make(seed: UInt32, dark: Bool, grayscale: Bool = false) -> SpacePalette {
    let hue = LCh(rgb: RGB(hex: seed)).h
    let scale = grayscale ? 0.0 : 1.0
    func tone(_ l: Double, _ c: Double, _ shift: Double) -> RGB {
      LCh(l: l, c: c * scale, h: (hue + shift + 360).truncatingRemainder(dividingBy: 360)).rgb
    }
    // Light tones stay dark enough for white text (about 4.5:1 at the start).
    return dark
      ? SpacePalette(
        gradientStart: tone(34, 32, -12), gradientEnd: tone(24, 36, 12),
        accent: tone(30, 44, 34), ink: tone(22, 30, 0))
      : SpacePalette(
        gradientStart: tone(50, 54, -12), gradientEnd: tone(40, 62, 12),
        accent: tone(46, 64, 34), ink: tone(26, 34, 0))
  }
}
