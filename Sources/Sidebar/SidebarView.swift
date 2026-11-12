import AppKit
import SidebarCore
import SwiftUI

/// The sidebar panel: the living surface and the sidebar. `frameHole.minX`
/// is the content's width.
struct FrameView: View {
  let model: SidebarModel
  @Environment(\.colorScheme) private var colorScheme

  /// The sidebar panel's corners.
  nonisolated static let outerCornerRadius: CGFloat = 16

  var body: some View {
    let palette = SpaceColors.palette(for: model.theme, dark: colorScheme == .dark)
    ZStack(alignment: .topLeading) {
      LivingSurface(palette: palette, phase: model.snapshot.activeTabID ?? 0)

      // The panel's width, not `isCollapsed`: while it slides, the panel keeps
      // its content.
      if model.frameHole.minX < 40 {
        // The left strip: hovering it slides the sidebar out over Chrome.
        Color.clear
          .frame(width: max(model.frameHole.minX, 0))
          .frame(maxHeight: .infinity)
          .contentShape(Rectangle())
          .onHover { if $0 { model.setPeeking(true) } }
      } else {
        SidebarView(model: model)
          .frame(width: max(model.frameHole.minX, 0))
          .frame(maxHeight: .infinity, alignment: .top)
      }
    }
    .foregroundStyle(.white)
    .environment(\.sidebarColors, SpaceColors.rows)
    .environment(\.spaceInk, Color(palette.ink))
    .environment(\.spaceAccent, Color(palette.accent))
  }
}

/// The sidebar sliding out over Chrome while collapsed.
struct PeekView: View {
  let model: SidebarModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let palette = SpaceColors.palette(for: model.theme, dark: colorScheme == .dark)
    SidebarView(model: model)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(LivingSurface(palette: palette, phase: model.snapshot.activeTabID ?? 0))
      .foregroundStyle(.white)
      .environment(\.sidebarColors, SpaceColors.rows)
      .environment(\.spaceInk, Color(palette.ink))
      .environment(\.spaceAccent, Color(palette.accent))
      .onHover { model.setPeeking($0) }
  }
}

enum SpaceColors {
  /// White rows on a vivid background, like Arc.
  static let rows = SidebarColors(
    background: nil, hover: .white.opacity(0.14), selected: .white.opacity(0.3), text: .white)

  /// The space's colors. Chrome's default theme uses the system accent color.
  static func palette(for theme: ProfileTheme, dark: Bool) -> SpacePalette {
    let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
    let fallback = RGB(r: accent.redComponent, g: accent.greenComponent, b: accent.blueComponent).hex
    return SpacePalette.make(seed: theme.seed ?? fallback, dark: dark, grayscale: theme.grayscale)
  }
}

private struct SpaceInkKey: EnvironmentKey {
  static let defaultValue = Color.black
}

private struct OnLightCardKey: EnvironmentKey {
  static let defaultValue = false
}

private struct SpaceAccentKey: EnvironmentKey {
  static let defaultValue = Color.white
}

extension EnvironmentValues {
  /// Dark text in the space's hue, for the white active-tab card.
  var spaceInk: Color {
    get { self[SpaceInkKey.self] }
    set { self[SpaceInkKey.self] = newValue }
  }

  /// Icons sit on a white card: a white icon needs a dark tile.
  var onLightCard: Bool {
    get { self[OnLightCardKey.self] }
    set { self[OnLightCardKey.self] = newValue }
  }

  /// The space's third tone, for small glows.
  var spaceAccent: Color {
    get { self[SpaceAccentKey.self] }
    set { self[SpaceAccentKey.self] = newValue }
  }
}

// MARK: - Sidebar

struct SidebarView: View {
  @Bindable var model: SidebarModel
  @Namespace private var selection
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      TopBar(model: model)
        .cascadeIn(delay: 0)
      AddressPill(tab: model.activeTab, onOpen: model.openPalette)
        .padding(.top, 8)
        .cascadeIn(delay: 0.03)
      if let problem = model.problem {
        ProblemBanner(problem: problem)
          .padding(.top, 8)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }

      SpaceContent(model: model, selection: selection, rowTransition: rowTransition)
        .id(model.spaceDirectory)
        .transition(spaceTransition)

      if model.spaces.count > 1 {
        SpaceSwitcher(
          spaces: model.spaces, current: model.spaceDirectory, icons: model.spaceIcons,
          onSwitch: model.switchSpace,
          onChooseIcon: { space, icon in model.spaceIcons[space.directory] = icon },
          onSettings: model.openSettings)
          .padding(.bottom, 8)
          .cascadeIn(delay: 0.22)
      }
    }
    .padding(.horizontal, 10)
    .padding(.top, 10)
    .motion(Motion.list, value: model.problem)
    .motion(Motion.list, value: model.spaceDirectory)
  }

  /// The space's content slides in from the side of the new space, as in Arc.
  private var spaceTransition: AnyTransition {
    reduceMotion ? .opacity : .push(from: model.spaceStep > 0 ? .trailing : .leading)
  }

  private var rowTransition: AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(
        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)),
        removal: .opacity.combined(with: .scale(scale: 0.88, anchor: .leading)))
  }
}

/// One space's favorites, pinned tabs, bookmarks and tabs. A new space
/// gets a new one, so the whole block slides on a space change.
private struct SpaceContent: View {
  @Bindable var model: SidebarModel
  let selection: Namespace.ID
  let rowTransition: AnyTransition

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      FavoritesGrid(model: model)
        .padding(.top, 12)
        .cascadeIn(delay: 0.06)

      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          if !model.spaceName.isEmpty {
            SpaceLabel(
              name: model.spaceName, tabCount: model.snapshot.tabs.count,
              clearableCount: model.clearableTabIDs.count,
              onClear: model.clearInactiveTabs)
              .cascadeIn(delay: 0.09)
          }

          let pinned = model.pinnedTabIDs
          ForEach(Array(model.pins.enumerated()), id: \.element.id) { index, pin in
            let tab = pinned[pin.id].flatMap { id in model.snapshot.tabs.first { $0.id == id } }
            PinRow(
              pin: pin, tab: tab,
              isActive: tab != nil && tab?.id == model.snapshot.activeTabID,
              selection: selection,
              onOpen: { model.openPin(pin) },
              onReset: { model.resetPin(pin) },
              onClose: { model.closePinnedTab(pin) },
              onUnpin: { model.unpin(pin) },
              onMove: { model.movePin($0, to: pin.id) },
              isKeyboardSelected: model.keyboardSelection == "pin:\(pin.id)",
              isRenaming: model.renamingPinID == pin.id,
              onBeginRename: { model.beginRename(pin) },
              onRename: { model.finishRename(pin, name: $0) })
            .cascadeIn(delay: 0.1 + Motion.stagger(index))
            .transition(rowTransition)
          }

          ForEach(Array(model.bookmarks.enumerated()), id: \.element.id) { index, node in
            BookmarkTree(node: node, depth: 0, model: model)
              .cascadeIn(delay: 0.1 + Motion.stagger(index))
          }

          if !model.bookmarks.isEmpty {
            FadingDivider()
              .padding(.vertical, 8)
              .cascadeIn(delay: 0.14)
          }

          let details = TabRow.details(for: model.snapshot.tabs)
          ForEach(Array(model.unpinnedTabs.enumerated()), id: \.element.id) { index, tab in
            TabRow(
              tab: tab,
              detail: details[tab.id],
              isActive: tab.id == model.snapshot.activeTabID,
              selection: selection,
              onSelect: { model.activate(tab) },
              onClose: { model.close(tab) },
              onFavorite: { model.addFavorite(tab) },
              onPin: { model.pin(tab) },
              isKeyboardSelected: model.keyboardSelection == "tab:\(tab.id)",
              onMove: { model.moveTab($0, to: tab.id) },
              onPreview: { frame in model.showPreview(frame.map { _ in tab }, frame ?? .zero) },
              previewDelay: { model.isPreviewing ? 0.06 : 0.75 })
            .cascadeIn(delay: 0.16 + Motion.stagger(index))
            .transition(rowTransition)
          }

          NewTabRow(onTap: model.newTab)
            .cascadeIn(delay: 0.2)
        }
        .motion(Motion.glide, value: model.snapshot.activeTabID)
        .motion(Motion.list, value: model.snapshot.tabs.map(\.id))
        .padding(.top, 10)
        .padding(.bottom, 18)
      }
      .scrollIndicators(.never)
      // Rows fade out at the list's edges instead of being cut off.
      .mask {
        VStack(spacing: 0) {
          LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
          Color.black
          LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
        }
      }
      .onScrollPhaseChange { _, phase in
        if phase != .idle { model.showPreview(nil, .zero) }
      }
    }
  }
}

private struct TopBar: View {
  let model: SidebarModel
  @State private var backTick = 0
  @State private var forwardTick = 0
  @State private var reloadTick = 0

  var body: some View {
    HStack(spacing: 6) {
      IconButton(
        symbol: "sidebar.left", help: model.isCollapsed ? "Keep Sidebar Open (⌃⌘S)" : "Collapse Sidebar (⌃⌘S)"
      ) { model.toggleCollapse() }
      Spacer()
      IconButton(symbol: "arrow.left", help: "Back") {
        backTick += 1
        model.navigate(.back)
      }
      .symbolEffect(.wiggle.left, options: .nonRepeating, value: backTick)
      IconButton(symbol: "arrow.right", help: "Forward") {
        forwardTick += 1
        model.navigate(.forward)
      }
      .symbolEffect(.wiggle.right, options: .nonRepeating, value: forwardTick)
      IconButton(symbol: "arrow.clockwise", help: "Reload") {
        reloadTick += 1
        model.navigate(.reload)
      }
      .symbolEffect(.rotate.clockwise, options: .nonRepeating, value: reloadTick)
    }
    .frame(height: 26)
  }
}

private struct IconButton: View {
  let symbol: String
  let help: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 26, height: 26)
        .background(Circle().fill(.white.opacity(hovering ? 0.16 : 0)))
        .contentShape(Circle())
    }
    .buttonStyle(PressStyle(scale: 0.86))
    .opacity(hovering ? 1 : 0.82)
    .onHover { hovering = $0 }
    .motion(.easeOut(duration: 0.14), value: hovering)
    .help(help)
  }
}

/// Shows the active tab's site; a click opens the Cmd+T palette.
private struct AddressPill: View {
  let tab: ChromeTab?
  let onOpen: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 8) {
        Group {
          if let tab, !tab.url.hasPrefix("chrome://") {
            Favicon(url: tab.url, size: 14)
          } else {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
          }
        }
        .frame(width: 16)
        .id(tab?.url.hostKey)
        .transition(.scale(scale: 0.5).combined(with: .opacity))

        Text(host)
          .font(.system(size: 13, weight: .medium))
          .kerning(-0.1)
          .lineLimit(1)
          .id(host)
          .transition(.push(from: .bottom))
        Spacer(minLength: 0)
        Text("⌘T")
          .font(.system(size: 10.5, weight: .semibold, design: .rounded))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
          .opacity(hovering ? 0.9 : 0)
          .offset(x: hovering ? 0 : 6)
      }
      .padding(.horizontal, 12)
      .frame(height: 36)
      .background(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(.white.opacity(hovering ? 0.22 : 0.14))
          .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 6 : 2, y: 1))
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .strokeBorder(.white.opacity(hovering ? 0.22 : 0.12), lineWidth: 0.5))
      .contentShape(Rectangle())
    }
    .buttonStyle(PressStyle(scale: 0.98))
    .onHover { hovering = $0 }
    .motion(.snappy(duration: 0.22), value: host)
    .motion(.easeOut(duration: 0.16), value: hovering)
    .help("Search tabs, bookmarks and history (⌘T)")
  }

  private var host: String {
    // Chrome's own pages (the new-tab page, settings) have no site to show.
    guard let tab, !tab.url.hasPrefix("chrome://") else { return "Search or enter URL" }
    return tab.url.hostKey ?? tab.title
  }
}

private extension String {
  /// The URL's host without `www.`.
  var hostKey: String? {
    guard let host = URL(string: self)?.host(), !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}

/// The space's favorites as icon tiles, four to a row. Only real favorites
/// show; an empty space shows one dashed tile that explains how to add one.
private struct FavoritesGrid: View {
  let model: SidebarModel
  @State private var dropTargeted = false
  private let columns = Array(
    repeating: GridItem(.flexible(), spacing: 8), count: FavoritesStore.columns)

  var body: some View {
    let favorites = model.favorites
    LazyVGrid(columns: columns, spacing: 8) {
      if favorites.isEmpty {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .frame(height: 44)
          .overlay(Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).opacity(0.6))
          .help("Drag a tab here, or right-click a tab and choose Add to Favorites")
      }
      ForEach(Array(favorites.enumerated()), id: \.element.id) { index, favorite in
        FavoriteTile(
          favorite: favorite,
          isActive: model.isActive(favorite),
          onOpen: { model.openFavorite(favorite) },
          onRemove: { model.removeFavorite(favorite) },
          onDrop: { text in
            if let id = FavoriteDrag.favoriteID(text) {
              model.moveFavorite(id, to: favorite.id)
            } else if let dropped = FavoriteDrag.parse(text) {
              model.addFavorite(dropped)
              if let added = model.favorites.last, added.url == dropped.url {
                model.moveFavorite(added.id, to: favorite.id)
              }
            } else {
              return false
            }
            return true
          })
        .transition(.scale(scale: 0.4).combined(with: .opacity))
      }
    }
    .padding(dropTargeted ? 4 : 0)
    .background(
      RoundedRectangle(cornerRadius: 15, style: .continuous)
        .fill(.white.opacity(dropTargeted ? 0.14 : 0))
        .strokeBorder(.white.opacity(dropTargeted ? 0.6 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    .scaleEffect(dropTargeted ? 1.02 : 1)
    .dropDestination(for: String.self) { items, _ in
      var handled = false
      for item in items {
        if let id = FavoriteDrag.favoriteID(item) {
          model.moveFavorite(id, to: nil)
          handled = true
        } else if let favorite = FavoriteDrag.parse(item) {
          model.addFavorite(favorite)
          handled = true
        }
      }
      if handled { Haptics.step() }
      return handled
    } isTargeted: { targeted in
      dropTargeted = targeted
      if targeted { Haptics.snap() }
    }
    .motion(Motion.press, value: favorites.map(\.id))
    .motion(Motion.press, value: dropTargeted)
  }
}

private struct FavoriteTile: View {
  let favorite: Favorite
  let isActive: Bool
  let onOpen: () -> Void
  let onRemove: () -> Void
  /// A tab or another favorite dropped on this tile. Returns `true` when used.
  let onDrop: (String) -> Bool
  @State private var hovering = false
  @State private var dropTargeted = false
  @State private var taps = 0
  @State private var tilt = CGSize.zero
  @State private var size = CGSize.zero
  @Environment(\.spaceAccent) private var accent
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      taps += 1
      onOpen()
    } label: {
      Favicon(url: favorite.url, size: 20)
        .environment(\.onLightCard, isActive)
        .keyframeAnimator(initialValue: 1.0, trigger: taps) { content, scale in
          content.scaleEffect(scale)
        } keyframes: { _ in
          SpringKeyframe(1.3, duration: 0.14, spring: .snappy)
          SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(isActive ? 0.94 : hovering ? 0.26 : 0.16))
            .shadow(color: isActive ? accent.opacity(0.9) : .clear, radius: 10)
            .shadow(color: .black.opacity(isActive ? 0.16 : hovering ? 0.14 : 0), radius: hovering ? 6 : 2, y: hovering ? 3 : 1))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(hovering && !isActive ? 0.25 : 0), lineWidth: 0.5))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(dropTargeted ? 0.9 : 0), lineWidth: 1.5))
        .scaleEffect(dropTargeted ? 0.92 : hovering ? 1.05 : 1)
        .offset(x: dropTargeted ? 4 : 0, y: hovering ? -1.5 : 0)
        // Leans toward the pointer.
        .rotation3DEffect(
          .degrees(hovering && !reduceMotion ? 14 : 0),
          axis: (x: -tilt.height, y: tilt.width, z: 0), perspective: 0.5)
        .contentShape(Rectangle())
    }
    .buttonStyle(PressStyle(scale: 0.9))
    .draggable(FavoriteDrag.payload(favoriteID: favorite.id)) {
      Favicon(url: favorite.url, size: 22)
        .frame(width: 44, height: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .dropDestination(for: String.self) { items, _ in
      let used = items.reduce(false) { $0 || onDrop($1) }
      if used { Haptics.step() }
      return used
    } isTargeted: { targeted in
      dropTargeted = targeted
      if targeted { Haptics.snap() }
    }
    .motion(Motion.press, value: dropTargeted)
    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    .onContinuousHover { phase in
      guard case .active(let location) = phase, size.width > 0 else { return }
      tilt = CGSize(
        width: (location.x / size.width - 0.5) * 2, height: (location.y / size.height - 0.5) * 2)
    }
    .onHover { hovering = $0 }
    .motion(Motion.trail, value: tilt)
    .motion(Motion.press, value: hovering)
    .motion(Motion.glide, value: isActive)
    .help(favorite.title)
    .contextMenu {
      Button("Remove from Favorites", role: .destructive, action: onRemove)
    }
  }
}

private struct SpaceLabel: View {
  let name: String
  let tabCount: Int
  /// Tabs that Clear would close.
  let clearableCount: Int
  let onClear: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(.white)
        .frame(width: 5, height: 5)
        .shadow(color: .white.opacity(0.8), radius: 3)
      Text(name.uppercased())
        .font(.system(size: 10.5, weight: .semibold))
        .kerning(0.9)
        .opacity(0.62)
      Spacer(minLength: 4)
      if hovering && clearableCount > 0 {
        ClearButton(count: clearableCount, onClear: onClear)
          .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity))
      } else {
        Text("\(tabCount)")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .contentTransition(.numericText(value: Double(tabCount)))
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(.white.opacity(0.14), in: Capsule())
          .opacity(0.62)
          .help("\(tabCount) open tabs in this window")
          .transition(.opacity)
      }
    }
    .frame(height: 20)
    .padding(.horizontal, 10)
    .padding(.top, 2)
    .padding(.bottom, 4)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .motion(.snappy, value: tabCount)
    .motion(Motion.press, value: hovering)
  }
}

/// Closes every tab but the active one and the tabs of favorites, like Arc's Clear.
private struct ClearButton: View {
  let count: Int
  let onClear: () -> Void
  @State private var hovering = false
  @State private var sweeps = 0

  var body: some View {
    Button {
      sweeps += 1
      onClear()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "arrow.down")
          .font(.system(size: 9, weight: .bold))
          .symbolEffect(.bounce.down, options: .nonRepeating, value: hovering)
        Text("Clear")
          .font(.system(size: 10.5, weight: .semibold))
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(.white.opacity(hovering ? 0.26 : 0.16), in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(PressStyle(scale: 0.9))
    .onHover { hovering = $0 }
    .motion(.easeOut(duration: 0.14), value: hovering)
    .help(count == 1 ? "Close 1 tab that is not active or a favorite" : "Close \(count) tabs that are not active or favorites")
  }
}

/// One letter icon per Chrome profile, like Arc's space bar, and a settings
/// button. A click brings that profile's window to the front.
private struct SpaceSwitcher: View {
  let spaces: [SidebarModel.Space]
  let current: String
  let icons: [String: String]
  let onSwitch: (SidebarModel.Space) -> Void
  let onChooseIcon: (SidebarModel.Space, String?) -> Void
  let onSettings: () -> Void
  @Namespace private var selection

  var body: some View {
    HStack(spacing: 4) {
      ForEach(spaces) { space in
        SpaceIcon(
          space: space, isCurrent: space.directory == current, icon: icons[space.directory],
          selection: selection, onChoose: { onChooseIcon(space, $0) }
        ) { onSwitch(space) }
      }
      Spacer(minLength: 0)
      IconButton(symbol: "gearshape", help: "Settings", action: onSettings)
    }
    .padding(.leading, 4)
    .frame(height: 30)
    .motion(Motion.glide, value: current)
  }
}

private struct SpaceIcon: View {
  let space: SidebarModel.Space
  let isCurrent: Bool
  /// `sf:<symbol>`, `emoji:<character>`, or `nil` for the first letter.
  let icon: String?
  let selection: Namespace.ID
  let onChoose: (String?) -> Void
  let onTap: () -> Void
  @State private var hovering = false
  @Environment(\.colorScheme) private var colorScheme

  static let symbols = [
    "house.fill", "briefcase.fill", "star.fill", "bolt.fill", "leaf.fill", "flame.fill",
    "heart.fill", "book.fill", "hammer.fill", "globe", "moon.fill", "paintpalette.fill",
  ]
  static let emoji = ["🏠", "💼", "🚀", "🎨", "🧪", "🌱", "🔥", "📚", "🎧", "☕️", "🌊", "⭐️"]

  var body: some View {
    let palette = SpaceColors.palette(for: space.theme, dark: colorScheme == .dark)
    Button(action: onTap) {
      glyph
        .font(.system(size: 11.5, weight: .bold, design: .rounded))
        .foregroundStyle(isCurrent ? Color(palette.ink) : .white.opacity(hovering ? 1 : 0.75))
        .frame(width: 24, height: 24)
        .background {
          if isCurrent {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(.white.opacity(0.94))
              .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
              .matchedGeometryEffect(id: "current-space", in: selection)
          } else {
            // The space's own colors show under the pointer.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(LinearGradient(
                colors: [Color(palette.gradientStart), Color(palette.gradientEnd)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
              .opacity(hovering ? 1 : 0)
              .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .strokeBorder(.white.opacity(hovering ? 0.35 : 0.22), lineWidth: 1))
          }
        }
        .scaleEffect(hovering && !isCurrent ? 1.08 : 1)
        .contentShape(Rectangle())
    }
    .buttonStyle(PressStyle(scale: 0.86))
    .onHover { hovering = $0 }
    .motion(Motion.press, value: hovering)
    .help(isCurrent ? space.name : "Switch to \(space.name)")
    .contextMenu {
      Menu("Symbol") {
        ForEach(Self.symbols, id: \.self) { symbol in
          Button { onChoose("sf:\(symbol)") } label: { Label(symbol.replacingOccurrences(of: ".fill", with: "").capitalized, systemImage: symbol) }
        }
      }
      Menu("Emoji") {
        ForEach(Self.emoji, id: \.self) { emoji in
          Button(emoji) { onChoose("emoji:\(emoji)") }
        }
      }
      if icon != nil {
        Divider()
        Button("Use First Letter") { onChoose(nil) }
      }
    }
  }

  @ViewBuilder private var glyph: some View {
    if let icon, icon.hasPrefix("sf:") {
      Image(systemName: String(icon.dropFirst(3))).font(.system(size: 11, weight: .semibold))
    } else if let icon, icon.hasPrefix("emoji:") {
      Text(String(icon.dropFirst(6))).font(.system(size: 13))
    } else {
      Text(letter)
    }
  }

  /// The first letter of the profile's name: Work → W.
  private var letter: String {
    space.name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "•"
  }
}

/// A hairline that fades out at both ends.
private struct FadingDivider: View {
  var body: some View {
    LinearGradient(
      colors: [.clear, .white.opacity(0.28), .white.opacity(0.28), .clear],
      startPoint: .leading, endPoint: .trailing)
    .frame(height: 0.5)
    .padding(.horizontal, 6)
  }
}

// MARK: - Rows

private struct TabRow: View {
  let tab: ChromeTab
  /// Part of the URL, shown when another tab has the same title.
  let detail: String?
  let isActive: Bool
  let selection: Namespace.ID
  let onSelect: () -> Void
  let onClose: () -> Void
  let onFavorite: () -> Void
  let onPin: () -> Void
  /// The keyboard has selected this row (⌃⌘↓).
  let isKeyboardSelected: Bool
  /// Another tab dropped on this one, by its ID.
  let onMove: (Int) -> Void
  /// Shows the preview card beside this row (its frame), or hides it (`nil`).
  let onPreview: (CGRect?) -> Void
  /// Seconds to rest on the row before its card shows.
  let previewDelay: () -> Double
  @State private var hovering = false
  @State private var dropTargeted = false
  @State private var frame = CGRect.zero
  @State private var previewTask: Task<Void, Never>?
  @Environment(\.spaceInk) private var ink

  var body: some View {
    Button {
      endPreview()
      onSelect()
    } label: {
      HStack(spacing: 10) {
        ZStack {
          Favicon(url: tab.url)
            .environment(\.onLightCard, isActive)
            .keyframeAnimator(initialValue: 1.0, trigger: isActive) { content, scale in
              content.scaleEffect(scale)
            } keyframes: { _ in
              SpringKeyframe(isActive ? 1.28 : 1.0, duration: 0.12, spring: .snappy)
              SpringKeyframe(1.0, duration: 0.36, spring: .bouncy)
            }
          if tab.isLoading {
            LoadingRing(size: 22)
              .foregroundStyle(isActive ? ink : .white)
              .transition(.opacity.combined(with: .scale(scale: 0.6)))
          }
        }
        .frame(width: 18, height: 18)

        Text(tab.title.isEmpty ? tab.url : tab.title)
          .font(.system(size: 13, weight: isActive ? .semibold : .regular))
          .kerning(-0.1)
          .lineLimit(1)
          .truncationMode(.tail)
          .contentTransition(.interpolate)
          .layoutPriority(1)
        if let detail {
          Text(detail)
            .font(.system(size: 11))
            .opacity(0.55)
            .lineLimit(1)
            .truncationMode(.middle)
            .transition(.opacity)
        }
        Spacer(minLength: 0)
        // Keeps the close button's space, so the title does not shift on hover.
        Color.clear.frame(width: 18)
      }
      .foregroundStyle(isActive ? AnyShapeStyle(ink) : AnyShapeStyle(.white))
      .padding(.horizontal, 10)
      .frame(height: 32)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if isActive {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(0.94))
            .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .matchedGeometryEffect(id: "active-card", in: selection)
        } else if hovering || isKeyboardSelected {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(0.13))
            .transition(.opacity)
        }
      }
      .overlay(alignment: .top) {
        // Where a dragged tab lands.
        if dropTargeted {
          Capsule().fill(.white).frame(height: 2).padding(.horizontal, 6).offset(y: -2)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
      }
      .keyboardRing(isKeyboardSelected)
      .contentShape(Rectangle())
    }
    .buttonStyle(PressStyle())
    .dropDestination(for: String.self) { items, _ in
      let ids = items.compactMap(FavoriteDrag.tabID).filter { $0 != tab.id }
      ids.forEach(onMove)
      if !ids.isEmpty { Haptics.step() }
      return !ids.isEmpty
    } isTargeted: { targeted in
      dropTargeted = targeted
      if targeted { Haptics.snap() }
    }
    .motion(Motion.press, value: dropTargeted)
    .draggable(FavoriteDrag.payload(url: tab.url, title: tab.title, tabID: tab.id)) {
      HStack(spacing: 8) {
        Favicon(url: tab.url)
        Text(tab.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .overlay(alignment: .trailing) {
      if hovering {
        CloseButton(onClose: onClose, tint: isActive ? ink : .white)
          .padding(.trailing, 7)
          .transition(.scale(scale: 0.5).combined(with: .opacity))
      }
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    .onHover { inside in
      hovering = inside
      inside ? beginPreview() : endPreview()
    }
    .onDisappear(perform: endPreview)
    .motion(.easeOut(duration: 0.14), value: hovering)
    .motion(Motion.press, value: tab.isLoading)
    .contextMenu {
      Button("Pin Tab", action: onPin)
      Button("Add to Favorites", action: onFavorite)
      Divider()
      Button("Close Tab", action: onClose)
    }
  }
}

/// A pinned tab. It keeps its place and its own URL. Without an open tab it
/// shows dimmed; a click opens it again.
private struct PinRow: View {
  let pin: Favorite
  /// The pin's open tab, if any.
  let tab: ChromeTab?
  let isActive: Bool
  let selection: Namespace.ID
  let onOpen: () -> Void
  let onReset: () -> Void
  let onClose: () -> Void
  let onUnpin: () -> Void
  /// Another pin dropped on this one.
  let onMove: (UUID) -> Void
  let isKeyboardSelected: Bool
  let isRenaming: Bool
  let onBeginRename: () -> Void
  /// The new name, or `nil` to cancel.
  let onRename: (String?) -> Void
  @State private var hovering = false
  @State private var draft = ""
  /// Return or Esc ended the rename, so losing focus must not save again.
  @State private var renameDone = false
  @FocusState private var fieldFocused: Bool
  @State private var dropTargeted = false
  @Environment(\.spaceInk) private var ink

  /// The tab has left the pin's page.
  private var wandered: Bool { tab.map { $0.url != pin.url } ?? false }

  var body: some View {
    if isRenaming { renameRow } else { row }
  }

  /// The row with a text field in place of the title.
  private var renameRow: some View {
    HStack(spacing: 10) {
      Favicon(url: tab?.url ?? pin.url)
        .frame(width: 18, height: 18)
      TextField("Pin name", text: $draft, prompt: Text(pageTitle))
        .textFieldStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .focused($fieldFocused)
        .onSubmit { end(draft) }
        .onExitCommand { end(nil) }
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.black.opacity(0.18))
        .strokeBorder(.white.opacity(0.55), lineWidth: 1.5))
    .onAppear {
      draft = pin.name ?? pageTitle
      renameDone = false
      // The panel becomes key a moment after the field appears.
      Task { fieldFocused = true }
    }
    // A click elsewhere ends the rename and keeps the text.
    .onChange(of: fieldFocused) { was, now in
      if was && !now { end(draft) }
    }
  }

  private func end(_ name: String?) {
    guard !renameDone else { return }
    renameDone = true
    onRename(name)
  }

  /// The title that the row shows without a name.
  private var pageTitle: String { Favorite(url: pin.url, title: pin.title).label(for: tab) }

  private var row: some View {
    Button(action: onOpen) {
      HStack(spacing: 10) {
        ZStack {
          Favicon(url: tab?.url ?? pin.url)
            .environment(\.onLightCard, isActive)
          if tab?.isLoading == true {
            LoadingRing(size: 22).foregroundStyle(isActive ? ink : .white)
          }
        }
        .frame(width: 18, height: 18)
        .opacity(tab == nil ? 0.55 : 1)
        Text(pin.label(for: tab))
          .font(.system(size: 13, weight: isActive ? .semibold : .regular))
          .kerning(-0.1)
          .lineLimit(1)
          .opacity(tab == nil ? 0.65 : 1)
        Spacer(minLength: 0)
        Color.clear.frame(width: wandered ? 40 : 18)
      }
      .foregroundStyle(isActive ? AnyShapeStyle(ink) : AnyShapeStyle(.white))
      .padding(.horizontal, 10)
      .frame(height: 32)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if isActive {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(0.94))
            .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .matchedGeometryEffect(id: "active-card", in: selection)
        } else if hovering || dropTargeted || isKeyboardSelected {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(dropTargeted ? 0.22 : 0.13))
            .transition(.opacity)
        }
      }
      .keyboardRing(isKeyboardSelected)
      .contentShape(Rectangle())
    }
    .buttonStyle(PressStyle())
    .simultaneousGesture(TapGesture(count: 2).onEnded(onBeginRename))
    .overlay(alignment: .trailing) {
      HStack(spacing: 4) {
        // The tab has wandered: a way back to the pinned page, like Arc.
        if wandered && hovering {
          Button(action: onReset) {
            Image(systemName: "arrow.uturn.backward")
              .font(.system(size: 9.5, weight: .bold))
              .frame(width: 18, height: 18)
              .contentShape(Circle())
          }
          .buttonStyle(PressStyle(scale: 0.8))
          .foregroundStyle(isActive ? ink : .white)
          .help("Back to \(pin.url)")
          .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
        if tab != nil && hovering {
          CloseButton(onClose: onClose, tint: isActive ? ink : .white)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
      }
      .padding(.trailing, 7)
    }
    .draggable(FavoriteDrag.payload(favoriteID: pin.id))
    .dropDestination(for: String.self) { items, _ in
      let ids = items.compactMap(FavoriteDrag.favoriteID)
      ids.forEach(onMove)
      if !ids.isEmpty { Haptics.step() }
      return !ids.isEmpty
    } isTargeted: { targeted in
      dropTargeted = targeted
      if targeted { Haptics.snap() }
    }
    .onHover { hovering = $0 }
    .motion(.easeOut(duration: 0.14), value: hovering)
    .motion(Motion.press, value: dropTargeted)
    .help(pin.url)
    .contextMenu {
      if wandered { Button("Back to Pinned Page", action: onReset) }
      Button("Rename…", action: onBeginRename)
      if pin.name != nil { Button("Use Page Title") { onRename("") } }
      Button("Unpin", action: onUnpin)
      if tab != nil {
        Divider()
        Button("Close Tab", action: onClose)
      }
    }
  }
}

extension TabRow {
  /// Shows the card after the pointer rests on the row.
  fileprivate func beginPreview() {
    previewTask?.cancel()
    let delay = previewDelay()
    previewTask = Task {
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      onPreview(frame)
    }
  }

  fileprivate func endPreview() {
    guard previewTask != nil else { return }
    previewTask?.cancel()
    previewTask = nil
    onPreview(nil)
  }

  /// Labels that tell apart tabs with the same title: the host (with its
  /// port) when their sites differ, else the path when their pages differ.
  /// Tabs on the very same page get no label.
  static func details(for tabs: [ChromeTab]) -> [Int: String] {
    var result: [Int: String] = [:]
    for group in Dictionary(grouping: tabs, by: \.title).values where group.count > 1 {
      let parts = group.map { (tab: $0, components: URLComponents(string: $0.url)) }
      func site(_ components: URLComponents?) -> String {
        let host = components?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        return components?.port.map { "\(host):\($0)" } ?? host
      }
      if Set(parts.map { site($0.components) }).count > 1 {
        for part in parts { result[part.tab.id] = site(part.components) }
      } else if Set(parts.map { $0.components?.path ?? "" }).count > 1 {
        for part in parts { result[part.tab.id] = part.components?.path }
      }
    }
    return result
  }
}

/// A tab dragged onto the favorites: its URL and title in one string.
enum FavoriteDrag {
  static let separator = "\u{1F}"

  static func payload(url: String, title: String) -> String { url + separator + title }

  /// A tab row's payload also carries the tab's ID, for reordering tabs.
  static func payload(url: String, title: String, tabID: Int) -> String {
    url + separator + title + separator + "tab:\(tabID)"
  }

  static func tabID(_ text: String) -> Int? {
    let parts = text.components(separatedBy: separator)
    guard parts.count >= 3, parts[parts.count - 1].hasPrefix("tab:") else { return nil }
    return Int(parts[parts.count - 1].dropFirst(4))
  }

  /// A favorite dragged to a new place in the grid.
  static let favoritePrefix = "sidebar-favorite:"

  static func payload(favoriteID: UUID) -> String { favoritePrefix + favoriteID.uuidString }

  static func favoriteID(_ text: String) -> UUID? {
    guard text.hasPrefix(favoritePrefix) else { return nil }
    return UUID(uuidString: String(text.dropFirst(favoritePrefix.count)))
  }

  static func parse(_ text: String) -> Favorite? {
    let parts = text.components(separatedBy: separator)
    let url = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard URL(string: url)?.scheme?.hasPrefix("http") == true else { return nil }
    return Favorite(url: url, title: parts.count > 1 && !parts[1].hasPrefix("tab:") ? parts[1] : url)
  }
}

private struct CloseButton: View {
  let onClose: () -> Void
  let tint: Color
  @State private var hovering = false

  var body: some View {
    Button(action: onClose) {
      Image(systemName: "xmark")
        .font(.system(size: 9.5, weight: .bold))
        .frame(width: 18, height: 18)
        .background(Circle().fill(tint.opacity(hovering ? 0.18 : 0)))
        .foregroundStyle(tint.opacity(hovering ? 1 : 0.7))
        .rotationEffect(.degrees(hovering ? 90 : 0))
        .contentShape(Circle())
    }
    .buttonStyle(PressStyle(scale: 0.8))
    .onHover { hovering = $0 }
    .motion(Motion.press, value: hovering)
    .help("Close Tab")
  }
}

private struct NewTabRow: View {
  let onTap: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 10) {
        Image(systemName: "plus")
          .font(.system(size: 12.5, weight: .semibold))
          .rotationEffect(.degrees(hovering ? 90 : 0))
          .frame(width: 18)
        Text("New Tab").font(.system(size: 13)).kerning(-0.1)
        Spacer(minLength: 0)
      }
      .opacity(hovering ? 1 : 0.72)
      .rowBackground(hovering: hovering)
    }
    .buttonStyle(PressStyle())
    .onHover { hovering = $0 }
    .motion(Motion.press, value: hovering)
  }
}

private struct LinkRow: View {
  let title: String
  let url: String
  let onOpen: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 10) {
        Favicon(url: url).frame(width: 18)
        Text(title.isEmpty ? url : title)
          .font(.system(size: 13))
          .kerning(-0.1)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .rowBackground(hovering: hovering)
    }
    .buttonStyle(PressStyle())
    .onHover { hovering = $0 }
    .motion(.easeOut(duration: 0.14), value: hovering)
    .help(url)
  }
}

private struct BookmarkTree: View {
  let node: BookmarkNode
  let depth: Int
  let model: SidebarModel
  @State private var hovering = false

  /// Open folders are kept per space, so they stay open after a reload.
  private var expanded: Bool { model.openFolders.contains(node.id) }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if node.isFolder {
      Button {
        withAnimation(Motion.animation(Motion.list, reduceMotion: reduceMotion)) {
          model.setFolder(node.id, open: !expanded)
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 8.5, weight: .bold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .opacity(hovering || expanded ? 0.8 : 0.4)
            .frame(width: 8)
          Image(systemName: expanded ? "folder.fill" : "folder")
            .font(.system(size: 13))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 18)
          Text(node.title).font(.system(size: 13)).kerning(-0.1).lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .rowBackground(hovering: hovering, leading: 4)
      }
      .buttonStyle(PressStyle())
      .onHover { hovering = $0 }
      .motion(.easeOut(duration: 0.14), value: hovering)

      if expanded {
        ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
          BookmarkTree(node: child, depth: depth + 1, model: model)
            .cascadeIn(delay: Motion.stagger(index, step: 0.022), distance: 6)
        }
      }
    } else {
      LinkRow(title: node.title, url: node.url ?? "") { model.open(node.url ?? "") }
        .padding(.leading, CGFloat(depth) * 12 + (depth > 0 ? 14 : 0))
    }
  }
}

// MARK: - Pieces

/// A page's icon: Chrome's own cached favicon, a symbol for Chrome's pages,
/// or a monogram tile for a site Chrome has no icon for.
struct Favicon: View {
  let url: String
  var size: CGFloat = 16
  @Environment(\.onLightCard) private var onLightCard

  var body: some View {
    let image = FaviconCache.shared.image(for: url)
    let needsBacking = onLightCard && image.map(FaviconCache.shared.isLight) == true
    icon(image)
      // A white icon on a white card gets a dark tile so it stays visible.
      .padding(needsBacking ? size * 0.14 : 0)
      .frame(width: size, height: size)
      .background {
        if needsBacking {
          RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(.black.opacity(0.82))
        }
      }
  }

  @ViewBuilder private func icon(_ image: NSImage?) -> some View {
    Group {
      if url.hasPrefix("chrome://") {
        Image(systemName: Self.chromeSymbol(for: url))
          .font(.system(size: size * 0.78, weight: .medium))
      } else if url.hasPrefix("file://") {
        Image(systemName: "doc.text")
          .font(.system(size: size * 0.78, weight: .medium))
      } else if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
      } else {
        Monogram(url: url, size: size)
      }
    }
  }

  static func chromeSymbol(for url: String) -> String {
    let page = URL(string: url)?.host() ?? ""
    return switch page {
    case "newtab", "new-tab-page": "sparkles"
    case "settings": "gearshape"
    case "extensions": "puzzlepiece.extension"
    case "history": "clock"
    case "downloads": "arrow.down.circle"
    case "bookmarks": "bookmark"
    default: "app.dashed"
    }
  }
}

/// A rounded tile with the site's initial, in the surrounding text color.
private struct Monogram: View {
  let url: String
  let size: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
      .fill(.quaternary)
      .overlay {
        if let letter {
          Text(letter).font(.system(size: size * 0.6, weight: .bold, design: .rounded))
        } else {
          Image(systemName: "server.rack").font(.system(size: size * 0.5, weight: .semibold))
        }
      }
  }

  /// The first letter of the site's name: `portal.vendgogh.io` → V.
  /// `nil` for a local address, which shows a server symbol.
  private var letter: String? {
    guard let host = FaviconIndex.host(of: url) else { return "?" }
    let labels = host.split(separator: ".")
    if host == "localhost" || labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }
    let name = labels.count >= 2 ? labels[labels.count - 2] : labels[0]
    return name.first.map { String($0).uppercased() }
  }
}

/// Decoded favicons from Chrome's cache, shared by every view.
@Observable
final class FaviconCache {
  static let shared = FaviconCache()

  private var index = FaviconIndex()
  @ObservationIgnored private var decoded: [Data: NSImage] = [:]
  @ObservationIgnored private var lightness: [ObjectIdentifier: Bool] = [:]
  @ObservationIgnored private var loading = false
  @ObservationIgnored private var lastRead: Date?
  @ObservationIgnored private var lastFile: URL?

  func image(for url: String) -> NSImage? {
    guard let data = index.icon(for: url) else { return nil }
    if let image = decoded[data] { return image }
    let image = NSImage(data: data)
    decoded[data] = image
    return image
  }

  /// The icon is mostly white, so it disappears on a white card.
  func isLight(_ image: NSImage) -> Bool {
    let key = ObjectIdentifier(image)
    if let known = lightness[key] { return known }
    let light = Self.measureLightness(image)
    lightness[key] = light
    return light
  }

  /// Draws the icon at 8 × 8 and averages the brightness of its visible pixels.
  private static func measureLightness(_ image: NSImage) -> Bool {
    let side = 8
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(
        data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
    var luminance = 0.0, coverage = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Double(pixels[index + 3]) / 255
      guard alpha > 0.1 else { continue }
      // Premultiplied: divide the alpha back out.
      let r = Double(pixels[index]) / 255 / alpha, g = Double(pixels[index + 1]) / 255 / alpha
      let b = Double(pixels[index + 2]) / 255 / alpha
      luminance += (0.2126 * r + 0.7152 * g + 0.0722 * b) * alpha
      coverage += alpha
    }
    guard coverage > 64 * 0.12 else { return false }
    return luminance / coverage > 0.82
  }

  /// Reads the profile's Favicons database in the background.
  func reload(profileDirectory: URL) {
    let file = profileDirectory.appending(path: "Favicons")
    // Read again only when Chrome has written the file since the last read.
    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    guard !loading, modified == nil || modified != lastRead || file != lastFile else { return }
    lastRead = modified
    lastFile = file
    loading = true
    Task.detached(priority: .utility) {
      let next = try? FaviconIndex.load(faviconsFile: file)
      await MainActor.run {
        if let next, next.byPage.count != self.index.byPage.count || next.byHost.keys != self.index.byHost.keys {
          self.index = next
          self.decoded = [:]
          self.lightness = [:]
        }
        self.loading = false
      }
    }
  }
}

private struct ProblemBanner: View {
  let problem: SidebarModel.Problem

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message).font(.caption)
      Button("Open System Settings") { NSWorkspace.shared.open(settingsURL) }
        .controlSize(.small)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var message: String {
    switch problem {
    case .automationDenied:
      "Sidebar cannot read Chrome's tabs. Allow Sidebar to control Google Chrome in Privacy & Security → Automation."
    case .accessibilityDenied:
      "Sidebar cannot follow Chrome's windows. Allow Sidebar in Privacy & Security → Accessibility."
    }
  }

  private var settingsURL: URL {
    switch problem {
    case .automationDenied:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    case .accessibilityDenied:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    }
  }
}

private extension View {
  /// A ring around the row that the keyboard has selected.
  func keyboardRing(_ shown: Bool) -> some View {
    overlay {
      if shown {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
          .transition(.opacity)
      }
    }
  }

  /// A plain row: 32 pt high, with a soft fill under the pointer.
  func rowBackground(hovering: Bool, leading: CGFloat = 10) -> some View {
    padding(.leading, leading)
      .padding(.trailing, 10)
      .frame(height: 32)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.white.opacity(hovering ? 0.13 : 0)))
      .contentShape(Rectangle())
  }
}
