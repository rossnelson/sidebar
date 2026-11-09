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
  /// The theme of the profile that owns Chrome's front window.
  var theme = ProfileTheme.standard
  /// The space's name: the Chrome profile's name.
  var spaceName = ""
  var favorites: [Favorite] = []
  /// Where Chrome's window sits inside the frame, top-left origin.
  var frameHole = CGRect.zero

  /// Opens the Cmd+T palette. Set by the app delegate.
  @ObservationIgnored var openPalette: () -> Void = {}

  var activeTab: ChromeTab? {
    snapshot.tabs.first { $0.id == snapshot.activeTabID }
  }

  enum Problem: Equatable {
    case automationDenied
    case accessibilityDenied
  }

  @ObservationIgnored let chrome = ChromeController()
  @ObservationIgnored private var bookmarksModified: Date?
  @ObservationIgnored private var themeModified: Date?
  /// Profile folder of Chrome's front window, for example `Profile 1`.
  @ObservationIgnored private(set) var profileDirectory: URL = ChromeProfile.lastUsedDirectory()
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

  /// Follows the profile of Chrome's front window, from its title.
  func updateProfile(windowTitle: String?) {
    guard let windowTitle else { return }
    let base = ChromeProfile.defaultBase
    guard
      let localState = try? Data(contentsOf: base.appending(path: "Local State")),
      let directory = ChromeProfiles.directory(
        forWindowTitle: windowTitle, profiles: ChromeProfiles.parse(localState: localState))
    else { return }
    let next = base.appending(path: directory)
    spaceName = ChromeProfiles.parse(localState: localState).first { $0.directory == directory }?.name ?? ""
    guard next != profileDirectory else { return }
    profileDirectory = next
    loadFavorites()
    bookmarksModified = nil
    themeModified = nil
    refreshTheme()
    refreshBookmarks()
    refreshRecents()
  }

  /// Re-reads the profile's theme only when its Preferences file has changed.
  func refreshTheme() {
    let file = profileDirectory.appending(path: "Preferences")
    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    guard modified != themeModified else { return }
    themeModified = modified
    guard let data = try? Data(contentsOf: file) else { return }
    let next = ProfileTheme.parse(preferences: data)
    if next != theme { theme = next }
  }

  /// Re-reads the Bookmarks file only when Chrome has changed it.
  func refreshBookmarks() {
    let file = profileDirectory.appending(path: "Bookmarks")
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
    let file = profileDirectory.appending(path: "History")
    do {
      recents = try ChromeHistory.recent(historyFile: file, limit: 30)
    } catch {
      log.error("History read failed: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: - Favorites

  private var favoritesStore: FavoritesStore {
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Sidebar")
    return FavoritesStore(folder: folder, profileDirectory: profileDirectory.lastPathComponent)
  }

  func loadFavorites() {
    favorites = favoritesStore.load()
  }

  func addFavorite(_ tab: ChromeTab) {
    saveFavorites(FavoritesStore.adding(
      Favorite(url: tab.url, title: tab.title.isEmpty ? tab.url : tab.title), to: favorites))
  }

  func removeFavorite(_ favorite: Favorite) {
    saveFavorites(favorites.filter { $0.id != favorite.id })
  }

  private func saveFavorites(_ next: [Favorite]) {
    guard next != favorites else { return }
    favorites = next
    do {
      try favoritesStore.save(next)
    } catch {
      log.error("Favorites save failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Switches to the favorite's tab when one is open, else opens it.
  func openFavorite(_ favorite: Favorite) {
    if let tab = favorite.matchingTab(in: snapshot.tabs) { return activate(tab) }
    open(favorite.url)
  }

  func isActive(_ favorite: Favorite) -> Bool {
    guard let activeTab else { return false }
    return favorite.matchingTab(in: snapshot.tabs)?.id == activeTab.id
  }

  // MARK: - Actions

  func navigate(_ navigation: ChromeScripts.Navigation) {
    perform { (chrome) throws(ChromeError) in try chrome.navigate(navigation) }
  }

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
    open(Destination.url(for: text))
  }

  /// Opens a palette result: switches to a tab, or opens a URL in a new tab.
  func open(_ result: PaletteResult) {
    switch result.kind {
    case let .tab(windowID, tabID):
      perform { (chrome) throws(ChromeError) in try chrome.activateTab(windowID: windowID, tabID: tabID) }
      refreshTabs()
    case .bookmark, .history, .url, .search:
      open(result.url)
    }
  }

  /// Everything the palette searches. Reads more history than the sidebar shows.
  func paletteSources() -> (tabs: [WindowTab], history: [HistoryItem]) {
    var tabs: [WindowTab] = []
    perform { (chrome) throws(ChromeError) in tabs = try chrome.allTabs() }
    let file = profileDirectory.appending(path: "History")
    let history = (try? ChromeHistory.recent(historyFile: file, limit: 2000)) ?? recents
    return (tabs, history)
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
