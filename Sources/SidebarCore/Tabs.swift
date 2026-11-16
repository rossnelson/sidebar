import Foundation

public struct ChromeTab: Identifiable, Sendable, Equatable {
  /// Chrome's own tab ID. Stable while the tab lives.
  public let id: Int
  public let title: String
  public let url: String
  /// The page is still loading.
  public let isLoading: Bool

  public init(id: Int, title: String, url: String, isLoading: Bool = false) {
    self.id = id
    self.title = title
    self.url = url
    self.isLoading = isLoading
  }
}

/// The tabs of Chrome's front window.
public struct TabSnapshot: Sendable, Equatable {
  public var tabs: [ChromeTab]
  /// 1-based, as AppleScript reports it.
  public var activeIndex: Int

  public init(tabs: [ChromeTab], activeIndex: Int) {
    self.tabs = tabs
    self.activeIndex = activeIndex
  }

  public var activeTabID: Int? {
    tabs.indices.contains(activeIndex - 1) ? tabs[activeIndex - 1].id : nil
  }

  public static let empty = TabSnapshot(tabs: [], activeIndex: 0)
}

/// Google Chrome's identity and navigation commands.
public enum ChromeScripts {
  public static let bundleID = "com.google.Chrome"

  public enum Navigation: String, Sendable { case back, forward, reload }
}

/// Tabs that left the front window between two reads.
public enum ClosedTabs {
  /// The tabs in `previous` that `next` lacks. Nothing when the two share no
  /// tab: then the front window changed, and no tab closed.
  public static func detect(previous: [ChromeTab], next: [ChromeTab]) -> [ChromeTab] {
    let nextIDs = Set(next.map(\.id))
    guard previous.contains(where: { nextIDs.contains($0.id) }) else { return [] }
    return previous.filter { !nextIDs.contains($0.id) && !$0.url.hasPrefix("chrome://") && !$0.url.isEmpty }
  }

  /// Moves a tab in a list the way `ChromeScripts.moveTab` moves it in Chrome.
  public static func moving(_ id: Int, to targetID: Int, in tabs: [ChromeTab]) -> [ChromeTab] {
    guard id != targetID, let from = tabs.firstIndex(where: { $0.id == id }),
      let to = tabs.firstIndex(where: { $0.id == targetID })
    else { return tabs }
    var next = tabs
    next.insert(next.remove(at: from), at: to)
    return next
  }
}

/// The sidebar's own tab order. Chrome's "move tab" Apple Event replaces the
/// moved tab with a new blank tab, so a drag in the sidebar changes only this
/// order, as Arc's sidebar does, and Chrome's tab strip keeps its order.
public enum TabOrder {
  /// `snapshot` with its tabs in `order`. Tabs that `order` does not name
  /// keep Chrome's order after the others. The active tab stays active.
  public static func apply(_ order: [Int], to snapshot: TabSnapshot) -> TabSnapshot {
    guard !order.isEmpty else { return snapshot }
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let sorted = snapshot.tabs.enumerated().sorted { a, b in
      let ra = rank[a.element.id] ?? order.count + a.offset
      let rb = rank[b.element.id] ?? order.count + b.offset
      return ra < rb
    }.map(\.element)
    let activeID = snapshot.activeTabID
    return TabSnapshot(tabs: sorted, activeIndex: (sorted.firstIndex { $0.id == activeID } ?? -1) + 1)
  }
}

/// Picks the Chrome process that is the person's own browser. Tools such as
/// chrome-devtools-mcp start a second Google Chrome with the same bundle ID,
/// and macOS then sends Apple Events by bundle ID to either one.
public enum ChromeInstance {
  /// Flags that a test or automation tool adds when it starts Chrome.
  static let automationFlags = [
    "--remote-debugging-pipe", "--remote-debugging-port", "--user-data-dir", "--enable-automation",
    "--headless", "--test-type",
  ]

  public static func isAutomation(arguments: [String]) -> Bool {
    arguments.contains { argument in automationFlags.contains { argument == $0 || argument.hasPrefix($0 + "=") } }
  }

  /// The first process that automation did not start, else the first process.
  public static func pick<ID>(_ candidates: [(id: ID, arguments: [String])]) -> ID? {
    (candidates.first { !isAutomation(arguments: $0.arguments) } ?? candidates.first)?.id
  }
}
