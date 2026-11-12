import AppKit
import SidebarCore
import SwiftUI

/// The drawer: the space's gradient and the sidebar. Its right part
/// (`frameHole`) lies under Chrome's window.
struct FrameView: View {
  let model: SidebarModel
  @Environment(\.colorScheme) private var colorScheme

  /// The drawer's corners.
  nonisolated static let outerCornerRadius: CGFloat = 16

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: FrameView.outerCornerRadius, style: .continuous)
        .fill(SpaceColors.gradient(for: model.theme, dark: colorScheme == .dark))

      // The visible width, not `isCollapsed`: while collapsing, the drawer keeps
      // its content until Chrome has covered it.
      if model.frameHole.minX < 40 {
        // The left border: hovering it slides the sidebar out over Chrome.
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
  }
}

/// The sidebar sliding out over Chrome while collapsed.
struct PeekView: View {
  let model: SidebarModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    SidebarView(model: model)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(SpaceColors.gradient(for: model.theme, dark: colorScheme == .dark)))
      .foregroundStyle(.white)
      .environment(\.sidebarColors, SpaceColors.rows)
      .onHover { model.setPeeking($0) }
  }
}

enum SpaceColors {
  /// White rows on a vivid background, like Arc.
  static let rows = SidebarColors(
    background: nil, hover: .white.opacity(0.14), selected: .white.opacity(0.3), text: .white)

  static func gradient(for theme: ProfileTheme, dark: Bool) -> LinearGradient {
    let palette = palette(for: theme, dark: dark)
    return LinearGradient(
      colors: [Color(palette.gradientStart), Color(palette.gradientEnd)],
      startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  /// The space's gradient. Chrome's default theme uses the system accent color.
  static func palette(for theme: ProfileTheme, dark: Bool) -> SpacePalette {
    let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
    let fallback = RGB(r: accent.redComponent, g: accent.greenComponent, b: accent.blueComponent).hex
    return SpacePalette.make(seed: theme.seed ?? fallback, dark: dark, grayscale: theme.grayscale)
  }
}

// MARK: - Sidebar

struct SidebarView: View {
  @Bindable var model: SidebarModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TopBar(model: model)
      AddressPill(tab: model.activeTab, onOpen: model.openPalette)
      FavoritesGrid(model: model)

      if let problem = model.problem {
        ProblemBanner(problem: problem)
      }

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if !model.spaceName.isEmpty {
            Text(model.spaceName)
              .font(.system(size: 12, weight: .semibold))
              .opacity(0.7)
              .padding(.horizontal, 10)
              .padding(.bottom, 4)
          }

          ForEach(model.bookmarks) { node in
            BookmarkTree(node: node, depth: 0, open: model.open)
          }

          if !model.bookmarks.isEmpty {
            Rectangle()
              .fill(.white.opacity(0.25))
              .frame(height: 1)
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
          }

          ForEach(model.snapshot.tabs) { tab in
            TabRow(
              tab: tab,
              isActive: tab.id == model.snapshot.activeTabID,
              onSelect: { model.activate(tab) },
              onClose: { model.close(tab) },
              onFavorite: { model.addFavorite(tab) })
          }

          NewTabRow(onTap: model.newTab)
        }
        .padding(.bottom, 12)
      }
      .scrollIndicators(.never)
    }
    .padding(.leading, 10)
    .padding(.trailing, 6)
    .padding(.top, 10)
  }
}

private struct TopBar: View {
  let model: SidebarModel

  var body: some View {
    HStack(spacing: 14) {
      IconButton(
        symbol: "sidebar.left", help: model.isCollapsed ? "Keep Sidebar Open (⌃⌘S)" : "Collapse Sidebar (⌃⌘S)",
        action: model.toggleCollapse)
      Spacer()
      IconButton(symbol: "arrow.left", help: "Back") { model.navigate(.back) }
      IconButton(symbol: "arrow.right", help: "Forward") { model.navigate(.forward) }
      IconButton(symbol: "arrow.clockwise", help: "Reload") { model.navigate(.reload) }
    }
    .padding(.horizontal, 6)
    .frame(height: 24)
  }
}

private struct IconButton: View {
  let symbol: String
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
    }
    .buttonStyle(.plain)
    .opacity(0.85)
    .help(help)
  }
}

/// Shows the active tab's site; a click opens the Cmd+T palette.
private struct AddressPill: View {
  let tab: ChromeTab?
  let onOpen: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "link").font(.system(size: 11, weight: .semibold)).opacity(0.7)
      Text(host).font(.system(size: 13, weight: .medium)).lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .frame(height: 34)
    .background(.white.opacity(hovering ? 0.24 : 0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture(perform: onOpen)
    .help("Search tabs, bookmarks and history (⌘T)")
  }

  private var host: String {
    guard let tab else { return "Search or enter URL" }
    guard let host = URL(string: tab.url)?.host() else { return tab.title }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}

/// The space's favorites as icon tiles, four to a row, with dim empty slots.
private struct FavoritesGrid: View {
  let model: SidebarModel
  private let columns = Array(
    repeating: GridItem(.flexible(), spacing: 8), count: FavoritesStore.columns)

  var body: some View {
    let favorites = model.favorites
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(0..<FavoritesStore.slotCount(for: favorites.count), id: \.self) { index in
        if favorites.indices.contains(index) {
          FavoriteTile(
            favorite: favorites[index],
            isActive: model.isActive(favorites[index]),
            onOpen: { model.openFavorite(favorites[index]) },
            onRemove: { model.removeFavorite(favorites[index]) })
        } else {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.1))
            .frame(height: 46)
            .help("Right-click a tab and choose Add to Favorites")
        }
      }
    }
  }
}

private struct FavoriteTile: View {
  let favorite: Favorite
  let isActive: Bool
  let onOpen: () -> Void
  let onRemove: () -> Void
  @State private var hovering = false

  var body: some View {
    Favicon(url: favorite.url, size: 20)
      .frame(maxWidth: .infinity)
      .frame(height: 46)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.white.opacity(isActive ? 0.5 : hovering ? 0.28 : 0.18)))
      .shadow(color: .black.opacity(isActive ? 0.15 : 0), radius: 3, y: 1)
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
      .onTapGesture(perform: onOpen)
      .help(favorite.title)
      .contextMenu {
        Button("Remove from Favorites", role: .destructive, action: onRemove)
      }
  }
}

// MARK: - Rows

private struct TabRow: View {
  let tab: ChromeTab
  let isActive: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  let onFavorite: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      Favicon(url: tab.url)
      Text(tab.title.isEmpty ? tab.url : tab.title)
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if hovering {
        Button(action: onClose) {
          Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(.plain)
        .opacity(0.8)
        .help("Close Tab")
      }
    }
    .rowStyle(highlighted: isActive, hovering: hovering)
    .shadow(color: .black.opacity(isActive ? 0.12 : 0), radius: 2, y: 1)
    .onHover { hovering = $0 }
    .onTapGesture(perform: onSelect)
    .contextMenu {
      Button("Add to Favorites", action: onFavorite)
      Divider()
      Button("Close Tab", action: onClose)
    }
  }
}

private struct NewTabRow: View {
  let onTap: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 16)
      Text("New Tab").font(.system(size: 13, weight: .medium))
      Spacer(minLength: 0)
    }
    .opacity(0.75)
    .rowStyle(highlighted: false, hovering: hovering)
    .onHover { hovering = $0 }
    .onTapGesture(perform: onTap)
  }
}

private struct LinkRow: View {
  let title: String
  let url: String
  let onOpen: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      Favicon(url: url)
      Text(title.isEmpty ? url : title)
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .rowStyle(highlighted: false, hovering: hovering)
    .onHover { hovering = $0 }
    .onTapGesture(perform: onOpen)
    .help(url)
  }
}

private struct BookmarkTree: View {
  let node: BookmarkNode
  let depth: Int
  let open: (String) -> Void
  @State private var expanded = false
  @State private var hovering = false

  var body: some View {
    if node.isFolder {
      HStack(spacing: 10) {
        Image(systemName: expanded ? "folder.fill" : "folder")
          .font(.system(size: 13))
          .frame(width: 16)
        Text(node.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.leading, CGFloat(depth) * 14)
      .rowStyle(highlighted: false, hovering: hovering)
      .onHover { hovering = $0 }
      .onTapGesture { withAnimation(.snappy(duration: 0.15)) { expanded.toggle() } }

      if expanded {
        ForEach(node.children) { child in
          BookmarkTree(node: child, depth: depth + 1, open: open)
        }
      }
    } else {
      LinkRow(title: node.title, url: node.url ?? "") { open(node.url ?? "") }
        .padding(.leading, CGFloat(depth) * 14)
    }
  }
}

// MARK: - Pieces

struct Favicon: View {
  let url: String
  var size: CGFloat = 16

  var body: some View {
    AsyncImage(url: Self.source(for: url)) { image in
      image.resizable().interpolation(.high)
    } placeholder: {
      Image(systemName: "globe").opacity(0.6)
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
  }

  /// Chrome's favicon cache is not readable from outside, so use Google's favicon service.
  static func source(for url: String) -> URL? {
    guard let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
    return URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(host)")
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
  func rowStyle(highlighted: Bool, hovering: Bool) -> some View {
    padding(.horizontal, 10)
      .frame(height: 34)
      .modifier(RowStyle(highlighted: highlighted, hovering: hovering, cornerRadius: 9))
  }
}
