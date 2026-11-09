import AppKit
import Observation
import OSLog
import SidebarCore

/// The sidebar's state: tabs of Chrome's front window, bookmarks and recent pages.
@Observable
final class SidebarModel {
  var snapshot = TabSnapshot.empty
  var bookmarks: [BookmarkNode] = []
  var recents: [HistoryItem] = []
  var query = ""
  var problem: Problem?

  enum Problem: Equatable {
    case automationDenied
    case accessibilityDenied
  }

  @ObservationIgnored let chrome = ChromeController()
  @ObservationIgnored private var bookmarksModified: Date?
  @ObservationIgnored private let log = Logger(subsystem: "com.ross.sidebar", category: "model")

  // MARK: - Refresh

  func refreshTabs() {
    do {
      let next = try chrome.frontWindowTabs()
      if next != snapshot { snapshot = next }
      if problem == .automationDenied { problem = nil }
    } catch .notAuthorized {
      problem = .automationDenied
    } catch .notRunning {
      snapshot = .empty
    } catch {
      log.error("Tab refresh failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Re-reads the Bookmarks file only when Chrome has changed it.
  func refreshBookmarks() {
    let file = ChromeProfile.lastUsedDirectory().appending(path: "Bookmarks")
    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    guard modified != bookmarksModified else { return }
    bookmarksModified = modified
    do {
      bookmarks = try ChromeBookmarks.parse(Data(contentsOf: file))
    } catch {
      log.error("Bookmarks read failed: \(String(describing: error), privacy: .public)")
    }
  }

  func refreshRecents() {
    let file = ChromeProfile.lastUsedDirectory().appending(path: "History")
    do {
      recents = try ChromeHistory.recent(historyFile: file, limit: 30)
    } catch {
      log.error("History read failed: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: - Actions

  func activate(_ tab: ChromeTab) {
    perform { (chrome) throws(ChromeError) in try chrome.activateTab(id: tab.id) }
    snapshot.activeIndex = (snapshot.tabs.firstIndex(of: tab) ?? -1) + 1
  }

  func close(_ tab: ChromeTab) {
    perform { (chrome) throws(ChromeError) in try chrome.closeTab(id: tab.id) }
    refreshTabs()
  }

  func open(_ url: String) {
    perform { (chrome) throws(ChromeError) in try chrome.openInNewTab(url) }
    refreshTabs()
  }

  func newTab() { open("chrome://newtab/") }

  /// Return in the search box: first matching tab, else first bookmark or recent page,
  /// else the text as a URL, else a Google search.
  func submitQuery() {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    defer { query = "" }
    if let tab = filteredTabs.first { return activate(tab) }
    if let link = filteredBookmarkLinks.first?.url ?? filteredRecents.first?.url { return open(link) }
    open(Self.destination(for: text))
  }

  static func destination(for text: String) -> String {
    if text.contains("://") { return text }
    if !text.contains(" "), text.contains(".") { return "https://\(text)" }
    var components = URLComponents(string: "https://www.google.com/search")!
    components.queryItems = [URLQueryItem(name: "q", value: text)]
    return components.url!.absoluteString
  }

  private func perform(_ action: (ChromeController) throws(ChromeError) -> Void) {
    do {
      try action(chrome)
    } catch .notAuthorized {
      problem = .automationDenied
    } catch {
      log.error("Chrome action failed: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: - Filtering

  var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

  private func matches(_ title: String, _ url: String?) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return true }
    return title.localizedCaseInsensitiveContains(needle)
      || (url?.localizedCaseInsensitiveContains(needle) ?? false)
  }

  var filteredTabs: [ChromeTab] { snapshot.tabs.filter { matches($0.title, $0.url) } }

  /// While searching, folders flatten to their matching links.
  var filteredBookmarkLinks: [BookmarkNode] {
    bookmarks.flatMap(\.allLinks).filter { matches($0.title, $0.url) }
  }

  var filteredRecents: [HistoryItem] { recents.filter { matches($0.title, $0.url) } }
}
