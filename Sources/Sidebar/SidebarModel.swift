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
  /// Every Chrome profile, for the space switcher.
  var spaces: [Space] = []
  /// The folder name of the current space's profile, for example `Profile 1`.
  var spaceDirectory = ""
  /// Where Chrome's window sits inside the frame, top-left origin.
  var frameHole = CGRect.zero

  /// Collapsed: only the border shows around Chrome, like Arc. Saved between launches.
  var isCollapsed = UserDefaults.standard.bool(forKey: "collapsed") {
    didSet { UserDefaults.standard.set(isCollapsed, forKey: "collapsed") }
  }
  /// While collapsed, the sidebar slides out over Chrome when the left border is hovered.
  var isPeeking = false

  /// Opens the Cmd+T palette. Set by the app delegate.
  @ObservationIgnored var openPalette: () -> Void = {}
  /// Collapses or expands the sidebar. Set by the app delegate.
  @ObservationIgnored var toggleCollapse: () -> Void = {}
  /// Shows or hides the peek. Set by the app delegate.
  @ObservationIgnored var setPeeking: (Bool) -> Void = { _ in }
  /// Brings a space's Chrome window to the front. Set by the app delegate.
  @ObservationIgnored var switchSpace: (Space) -> Void = { _ in }
  /// Shows a tab's preview card beside a row (its frame in the sidebar
  /// window, top-left origin), or hides it. Set by the app delegate.
  @ObservationIgnored var showPreview: (ChromeTab?, CGRect) -> Void = { _, _ in }
  /// The preview card is on screen, so the next row shows its card at once.
  @ObservationIgnored var isPreviewing = false
  /// Opens the Settings window. Set by the app delegate.
  @ObservationIgnored var openSettings: () -> Void = {}
  /// Shows a short message over Chrome. Set by the app delegate.
  @ObservationIgnored var notify: (String, String) -> Void = { _, _ in }

  /// A Chrome profile shown as a space.
  struct Space: Identifiable, Equatable {
    var id: String { directory }
    let directory: String
    let name: String
    let theme: ProfileTheme
  }

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
    let name = ChromeProfiles.parse(localState: localState).first { $0.directory == directory }?.name ?? ""
    if name != spaceName { spaceName = name }
    if directory != spaceDirectory { spaceDirectory = directory }
    guard next != profileDirectory else { return }
    profileDirectory = next
    loadFavorites()
    bookmarksModified = nil
    themeModified = nil
    refreshTheme()
    refreshBookmarks()
    refreshRecents()
    FaviconCache.shared.reload(profileDirectory: next)
  }

  @ObservationIgnored private var spacesModified: [Date?] = []

  /// Re-reads the profile list and each profile's colors when Chrome has changed them.
  func refreshSpaces() {
    let base = ChromeProfile.defaultBase
    func modified(_ url: URL) -> Date? {
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    guard let localState = try? Data(contentsOf: base.appending(path: "Local State")) else { return }
    let profiles = ChromeProfiles.parse(localState: localState)
    let stamps = [modified(base.appending(path: "Local State"))]
      + profiles.map { modified(base.appending(path: $0.directory).appending(path: "Preferences")) }
    guard stamps != spacesModified else { return }
    spacesModified = stamps
    let next = profiles.map { profile in
      let preferences = try? Data(contentsOf: base.appending(path: profile.directory).appending(path: "Preferences"))
      return Space(
        directory: profile.directory, name: profile.name,
        theme: preferences.map(ProfileTheme.parse(preferences:)) ?? .standard)
    }
    if next != spaces { spaces = next }
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
    let files = ChromeBookmarks.fileNames.map { profileDirectory.appending(path: $0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    let modified = files
      .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
      .max()
    guard modified != bookmarksModified else { return }
    bookmarksModified = modified
    do {
      bookmarks = try ChromeBookmarks.parse(files.map { try Data(contentsOf: $0) })
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
    addFavorite(Favorite(url: tab.url, title: tab.title.isEmpty ? tab.url : tab.title))
  }

  func addFavorite(_ favorite: Favorite) {
    saveFavorites(FavoritesStore.adding(favorite, to: favorites))
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

  /// The space before (`-1`) or after (`1`) the current one, for a swipe.
  func neighborSpace(_ step: Int) -> Space? {
    guard let index = spaces.firstIndex(where: { $0.directory == spaceDirectory }) else { return nil }
    let next = index + step
    return spaces.indices.contains(next) ? spaces[next] : nil
  }

  /// Moves a favorite to another favorite's place, or to the end.
  func moveFavorite(_ id: UUID, to target: UUID?) {
    saveFavorites(FavoritesStore.moving(id, to: target, in: favorites))
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

  /// Arc's "Clear": closes every tab except the active one and the tabs of favorites.
  func clearInactiveTabs() {
    let ids = TabCleanup.idsToClose(in: snapshot.tabs, activeID: snapshot.activeTabID, favorites: favorites)
    guard !ids.isEmpty else { return }
    perform { (chrome) throws(ChromeError) in try chrome.closeTabs(ids: ids) }
    refreshTabs()
    notify(ids.count == 1 ? "Closed 1 tab" : "Closed \(ids.count) tabs", "checkmark.circle")
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
