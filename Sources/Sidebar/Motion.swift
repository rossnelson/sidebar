import AppKit
import SidebarCore
import SwiftUI

// MARK: - Motion presets

/// The app's motion vocabulary. Every preset falls back to a short fade when
/// Reduce Motion is on, so nothing moves across the screen.
enum Motion {
  /// Selection moving between rows (the active-tab card, the palette highlight).
  static let glide = Animation.spring(response: 0.34, dampingFraction: 0.82)
  /// A press or a hover: quick, with a small overshoot.
  static let press = Animation.spring(response: 0.22, dampingFraction: 0.62)
  /// Rows arriving or leaving.
  static let list = Animation.spring(response: 0.38, dampingFraction: 0.86)
  /// The surface re-forming after a tab switch: slow and soft.
  static let surface = Animation.smooth(duration: 1.6)
  /// A light that trails the pointer.
  static let trail = Animation.interpolatingSpring(stiffness: 120, damping: 18)

  static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
    reduceMotion ? .easeOut(duration: 0.15) : animation
  }

  /// The delay before the item at `index` in a cascade.
  static func stagger(_ index: Int, step: Double = 0.028, cap: Int = 14) -> Double {
    Double(min(index, cap)) * step
  }
}

extension View {
  /// `withAnimation`-style modifier that respects Reduce Motion.
  func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
    modifier(MotionModifier(animation: animation, value: value))
  }

  /// Fades and lifts in when it appears, after `delay`. Used for cascades.
  func cascadeIn(delay: Double, distance: CGFloat = 8) -> some View {
    modifier(CascadeIn(delay: delay, distance: distance))
  }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
  let animation: Animation
  let value: V
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.animation(Motion.animation(animation, reduceMotion: reduceMotion), value: value)
  }
}

private struct CascadeIn: ViewModifier {
  let delay: Double
  let distance: CGFloat
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .offset(y: shown || reduceMotion ? 0 : distance)
      .blur(radius: shown || reduceMotion ? 0 : 3)
      .onAppear {
        withAnimation(Motion.animation(Motion.list, reduceMotion: reduceMotion).delay(delay)) { shown = true }
      }
  }
}

// MARK: - Buttons

/// A row or tile that sinks a little under the pointer when pressed and
/// springs back on release.
struct PressStyle: ButtonStyle {
  var scale: CGFloat = 0.97
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
      .brightness(configuration.isPressed ? -0.04 : 0)
      .animation(Motion.animation(Motion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
  }
}

// MARK: - Living surface

/// The sidebar's surface: a mesh gradient in the space's colors that re-forms
/// slowly when `phase` changes, a light that follows the pointer, a fine grain
/// and a lit top edge. Nothing runs while nothing changes.
struct LivingSurface: View {
  let palette: SpacePalette
  /// Changes on each tab switch; the mesh flows to a new shape.
  let phase: Int
  var cornerRadius: CGFloat = FrameView.outerCornerRadius
  @State private var pointer: CGPoint?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    ZStack {
      MeshGradient(width: 3, height: 3, points: points, colors: colors)
        .motion(Motion.surface, value: phase)

      // The pointer light: only computed while the pointer moves.
      GeometryReader { proxy in
        if let pointer {
          RadialGradient(
            colors: [.white.opacity(0.22), .white.opacity(0.06), .clear],
            center: UnitPoint(x: pointer.x / max(proxy.size.width, 1), y: pointer.y / max(proxy.size.height, 1)),
            startRadius: 0, endRadius: 220)
          .blendMode(.softLight)
          .transition(.opacity)
        }
      }
      .allowsHitTesting(false)

      Grain.image
        .resizable(resizingMode: .tile)
        .opacity(0.06)
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }
    .clipShape(shape)
    .overlay(
      shape.strokeBorder(
        LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.04), .clear], startPoint: .top, endPoint: .center),
        lineWidth: 0.75)
    )
    .onContinuousHover { hover in
      switch hover {
      case .active(let location):
        withAnimation(reduceMotion ? nil : Motion.trail) { pointer = location }
      case .ended:
        withAnimation(.easeOut(duration: 0.4)) { pointer = nil }
      }
    }
  }

  private var colors: [Color] {
    let a = Color(palette.gradientStart), b = Color(palette.gradientEnd), c = Color(palette.accent)
    return [
      a, a, c,
      a, c, b,
      c, b, b,
    ]
  }

  /// The inner points drift with `phase`; the edges stay on the edges.
  private var points: [SIMD2<Float>] {
    let t = Float(phase)
    func wobble(_ seed: Float, _ amount: Float) -> Float { sin(t * 1.7 + seed) * amount }
    return [
      [0, 0], [0.5 + wobble(1, 0.18), 0], [1, 0],
      [0, 0.5 + wobble(2, 0.16)], [0.5 + wobble(3, 0.2), 0.5 + wobble(4, 0.2)], [1, 0.5 + wobble(5, 0.16)],
      [0, 1], [0.5 + wobble(6, 0.18), 1], [1, 1],
    ]
  }
}

/// A small tile of random noise, made once.
enum Grain {
  static let image: Image = {
    let size = 96
    var pixels = [UInt8](repeating: 0, count: size * size)
    var seed: UInt32 = 0x9E37_79B9
    for index in pixels.indices {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      pixels[index] = UInt8(truncatingIfNeeded: seed >> 24)
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let cgImage = CGImage(
      width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return Image(decorative: cgImage, scale: 2)
  }()
}

// MARK: - Loading ring

/// A thin arc that circles a favicon while its page loads. It runs only while shown.
struct LoadingRing: View {
  var size: CGFloat = 22
  @State private var spinning = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Circle()
      .trim(from: 0, to: 0.28)
      .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
      .frame(width: size, height: size)
      .rotationEffect(.degrees(spinning ? 360 : 0))
      .opacity(reduceMotion ? 0.6 : 0.9)
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
      }
  }
}
