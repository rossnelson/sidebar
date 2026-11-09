import AppKit
import SidebarCore
import SwiftUI

struct SidebarView: View {
  @Bindable var model: SidebarModel

  var body: some View {
    VStack(spacing: 0) {
      SearchField(text: $model.query, onSubmit: model.submitQuery)
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)

      if let problem = model.problem {
        ProblemBanner(problem: problem)
      }

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 1) {
          SectionHeader(title: "Tabs") {
            Button(action: model.newTab) { Image(systemName: "plus") }
              .buttonStyle(.borderless)
              .help("New Tab")
          }
          ForEach(model.filteredTabs) { tab in
            TabRow(
              tab: tab,
              isActive: tab.id == model.snapshot.activeTabID,
              onSelect: { model.activate(tab) },
              onClose: { model.close(tab) })
          }

          if model.isSearching {
            if !model.filteredBookmarkLinks.isEmpty { SectionHeader(title: "Bookmarks") }
            ForEach(model.filteredBookmarkLinks) { link in
              LinkRow(title: link.title, url: link.url ?? "") { model.open(link.url ?? "") }
            }
          } else if !model.bookmarks.isEmpty {
            SectionHeader(title: "Bookmarks")
            ForEach(model.bookmarks) { node in
              BookmarkTree(node: node, depth: 0, open: model.open)
            }
          }

          if !model.filteredRecents.isEmpty {
            SectionHeader(title: "Recent")
            ForEach(model.filteredRecents.prefix(model.isSearching ? 30 : 12)) { item in
              LinkRow(title: item.title, url: item.url) { model.open(item.url) }
            }
          }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 12)
      }
    }
    .modifier(Themed(theme: model.theme))
  }
}

// MARK: - Rows

private struct TabRow: View {
  let tab: ChromeTab
  let isActive: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 8) {
      Favicon(url: tab.url)
      Text(tab.title.isEmpty ? tab.url : tab.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if hovering {
        Button(action: onClose) {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
        }
        .buttonStyle(.borderless)
        .help("Close Tab")
      }
    }
    .rowStyle(highlighted: isActive, hovering: hovering)
    .onHover { hovering = $0 }
    .onTapGesture(perform: onSelect)
  }
}

private struct LinkRow: View {
  let title: String
  let url: String
  let onOpen: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 8) {
      Favicon(url: url)
      Text(title.isEmpty ? url : title).lineLimit(1).truncationMode(.tail)
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
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .rotationEffect(.degrees(expanded ? 90 : 0))
          .frame(width: 10)
        Image(systemName: "folder").foregroundStyle(.secondary)
        Text(node.title).lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.leading, CGFloat(depth) * 12)
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
        .padding(.leading, CGFloat(depth) * 12 + (depth > 0 ? 16 : 0))
    }
  }
}

// MARK: - Pieces

private struct SectionHeader<Accessory: View>: View {
  let title: String
  @ViewBuilder var accessory: Accessory

  var body: some View {
    HStack {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      Spacer()
      accessory
    }
    .padding(.horizontal, 8)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }
}

extension SectionHeader where Accessory == EmptyView {
  init(title: String) {
    self.init(title: title) { EmptyView() }
  }
}

struct Favicon: View {
  let url: String

  var body: some View {
    AsyncImage(url: Self.source(for: url)) { image in
      image.resizable().interpolation(.high)
    } placeholder: {
      Image(systemName: "globe").foregroundStyle(.tertiary)
    }
    .frame(width: 16, height: 16)
  }

  /// Chrome's favicon cache is not readable from outside, so use Google's favicon service.
  static func source(for url: String) -> URL? {
    guard let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
    return URL(string: "https://www.google.com/s2/favicons?sz=32&domain=\(host)")
  }
}

private struct SearchField: View {
  @Binding var text: String
  let onSubmit: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search or enter URL", text: $text)
        .textFieldStyle(.plain)
        .onSubmit(onSubmit)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
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
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
    .padding(.horizontal, 10)
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
    padding(.horizontal, 8)
      .padding(.vertical, 5)
      .modifier(RowStyle(highlighted: highlighted, hovering: hovering))
  }
}
