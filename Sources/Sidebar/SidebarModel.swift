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
  /// The space's pinned tabs. Their open tabs show in the pinned section, not with the other tabs.
  var pins: [Favorite] = []
  /// Tabs that Sidebar closed, newest first, for the palette.
  var archived: [ArchivedTab] = []
  /// Tabs that closed a short time ago, newest first. Sidebar sees them leave
  /// while it reads Chrome's tabs.
  var recentlyClosed: [ChromeTab] = []
  /// Bookmark folders that are open, in the current space. Kept between launches.
  var openFolders: Set<String> = []
  /// A chosen icon for each space: `sf:<symbol>` or `emoji:<character>`.
  var spaceIcons: [String: String] = UserDefaults.standard.dictionary(forKey: "spaceIcons") as? [String: String] ?? [:] {
    didSet { UserDefaults.standard.set(spaceIcons, forKey: "spaceIcons") }
  }
  /// The row that the keyboard has selected, while the sidebar has keyboard focus.
  var keyboardSelection: String?
  /// `1` when the last space change went to a later space, `-1` to an earlier one.
  var spaceStep = 1
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
  /// Gives the keyboard back to Chrome. Set by the app delegate.
  @ObservationIgnored var endKeyboardFocus: () -> Void = {}
  /// Tab IDs that Sidebar closed itself, so they do not count as recently closed.
  @ObservationIgnored private var closedBySidebar: Set<Int> = []
  /// Copies the active tab's URL. Set by the app delegate.
  @ObservationIgnored var copyURL: () -> Void = {}
  /// Each pin's open tab, kept while that tab navigates away from the pin.
  @ObservationIgnored private var pinTabIDs: [UUID: Int] = [:]
  /// When each tab was last the active tab, for auto-archive.
  @ObservationIgnored private var lastActive: [Int: Date] = [:]

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
      noteClosedTabs(next)
      pinTabIDs = PinMatching.match(pins: pins, tabs: next.tabs, remembered: pinTabIDs)
      noteActivity(next)
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
    if directory != spaceDirectory {
      let order = spaces.map(\.directory)
      if let from = order.firstIndex(of: spaceDirectory), let to = order.firstIndex(of: directory) {
        spaceStep = to > from ? 1 : -1
      }
      spaceDirectory = directory
    }
    guard next != profileDirectory else { return }
    profileDirectory = next
    loadFavorites()
    loadOpenFolders()
    pinTabIDs = [:]
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

  private var pinsStore: FavoritesStore {
    FavoritesStore(file: favoritesStore.file.deletingLastPathComponent()
      .appending(path: "pins-\(profileDirectory.lastPathComponent).json"))
  }

  private var archiveStore: ArchiveStore {
    ArchiveStore(folder: favoritesStore.file.deletingLastPathComponent(), profileDirectory: profileDirectory.lastPathComponent)
  }

  /// Loads the space's favorites, pins and archive.
  func loadFavorites() {
    favorites = favoritesStore.load()
    pins = pinsStore.load()
    archived = archiveStore.load()
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

  // MARK: - Folders

  private var openFoldersKey: String { "openFolders-\(profileDirectory.lastPathComponent)" }

  func loadOpenFolders() {
    openFolders = Set(UserDefaults.standard.stringArray(forKey: openFoldersKey) ?? [])
  }

  func setFolder(_ id: String, open: Bool) {
    if open { openFolders.insert(id) } else { openFolders.remove(id) }
    UserDefaults.standard.set(Array(openFolders), forKey: openFoldersKey)
  }

  // MARK: - Recently closed

  private func noteClosedTabs(_ next: TabSnapshot) {
    let closed = ClosedTabs.detect(previous: snapshot.tabs, next: next.tabs)
      .filter { !closedBySidebar.contains($0.id) }
    closedBySidebar.subtract(snapshot.tabs.map(\.id))
    guard !closed.isEmpty else { return }
    var seen: Set<String> = []
    recentlyClosed = Array((closed.reversed() + recentlyClosed).filter { seen.insert($0.url).inserted }.prefix(30))
  }

  /// Opens a recently closed tab again.
  func reopen(url: String) {
    recentlyClosed.removeAll { $0.url == url }
    open(url)
  }

  // MARK: - Tab order

  /// Moves a tab to another tab's place, in the sidebar at once and then in Chrome.
  func moveTab(_ id: Int, to targetID: Int) {
    let moved = ClosedTabs.moving(id, to: targetID, in: snapshot.tabs)
    guard moved != snapshot.tabs else { return }
    let activeID = snapshot.activeTabID
    snapshot.tabs = moved
    snapshot.activeIndex = (moved.firstIndex { $0.id == activeID } ?? -1) + 1
    perform { (chrome) throws(ChromeError) in try chrome.moveTab(id: id, to: targetID) }
  }

  // MARK: - Keyboard

  /// The rows the keyboard moves through: pinned tabs, then the other tabs.
  var keyboardRows: [String] {
    pins.map { "pin:\($0.id)" } + unpinnedTabs.map { "tab:\($0.id)" }
  }

  /// Starts on the active row.
  func beginKeyboardSelection() {
    let rows = keyboardRows
    let activeRow = snapshot.activeTabID.map { id in
      pinnedTabIDs.first { $0.value == id }.map { "pin:\($0.key)" } ?? "tab:\(id)"
    }
    keyboardSelection = activeRow.flatMap { rows.contains($0) ? $0 : nil } ?? rows.first
  }

  func moveKeyboardSelection(_ step: Int) {
    let rows = keyboardRows
    guard !rows.isEmpty else { return }
    let index = keyboardSelection.flatMap(rows.firstIndex(of:)) ?? 0
    keyboardSelection = rows[min(max(index + step, 0), rows.count - 1)]
  }

  /// Return: opens the selected row and gives the keyboard back to Chrome.
  func openKeyboardSelection() {
    guard let row = keyboardSelection else { return }
    if let pin = pin(forRow: row) { openPin(pin) } else if let tab = tab(forRow: row) { activate(tab) }
    endKeyboardFocus()
  }

  /// Delete: closes the selected row's tab and selects the next row.
  func closeKeyboardSelection() {
    guard let row = keyboardSelection else { return }
    let rows = keyboardRows
    let index = rows.firstIndex(of: row) ?? 0
    if let pin = pin(forRow: row) {
      closePinnedTab(pin)
      return
    }
    guard let tab = tab(forRow: row) else { return }
    close(tab)
    let remaining = keyboardRows
    keyboardSelection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
  }

  private func pin(forRow row: String) -> Favorite? {
    guard row.hasPrefix("pin:") else { return nil }
    return pins.first { "pin:\($0.id)" == row }
  }

  private func tab(forRow row: String) -> ChromeTab? {
    guard row.hasPrefix("tab:") else { return nil }
    return snapshot.tabs.first { "tab:\($0.id)" == row }
  }

  // MARK: - Palette shortcuts

  /// Favorites, pinned tabs and other spaces, for the palette's search.
  var paletteShortcuts: [PaletteResult] {
    favorites.map {
      PaletteResult(id: "favorite-\($0.id)", kind: .shortcut("favorite:\($0.id)"), title: $0.title, url: $0.url, badge: "Favorite")
    }
      + pins.map {
        PaletteResult(id: "pin-\($0.id)", kind: .shortcut("pin:\($0.id)"), title: $0.title, url: $0.url, badge: "Pinned")
      }
      + spaces.filter { $0.directory != spaceDirectory }.map {
        PaletteResult(
          id: "space-\($0.directory)", kind: .shortcut("space:\($0.directory)"), title: $0.name,
          url: "space:\($0.directory)", symbol: "square.stack", badge: "Space")
      }
  }

  private func openShortcut(_ id: String) {
    if id.hasPrefix("favorite:"), let favorite = favorites.first(where: { "favorite:\($0.id)" == id }) {
      openFavorite(favorite)
    } else if id.hasPrefix("pin:"), let pin = pins.first(where: { "pin:\($0.id)" == id }) {
      openPin(pin)
    } else if id.hasPrefix("space:"), let space = spaces.first(where: { "space:\($0.directory)" == id }) {
      switchSpace(space)
    }
  }

  // MARK: - Pins

  /// Each pin's open tab ID, from the last tab refresh.
  var pinnedTabIDs: [UUID: Int] {
    PinMatching.match(pins: pins, tabs: snapshot.tabs, remembered: pinTabIDs)
  }

  /// The tabs that are not pinned, for the tab list.
  var unpinnedTabs: [ChromeTab] {
    let pinned = Set(pinnedTabIDs.values)
    return snapshot.tabs.filter { !pinned.contains($0.id) }
  }

  func pin(_ tab: ChromeTab) {
    guard !pins.contains(where: { $0.url == tab.url }) else { return }
    let pin = Favorite(url: tab.url, title: tab.title.isEmpty ? tab.url : tab.title)
    pinTabIDs[pin.id] = tab.id
    savePins(pins + [pin])
  }

  func unpin(_ pin: Favorite) {
    pinTabIDs[pin.id] = nil
    savePins(pins.filter { $0.id != pin.id })
  }

  func movePin(_ id: UUID, to target: UUID?) {
    savePins(FavoritesStore.moving(id, to: target, in: pins))
  }

  /// Switches to the pin's tab, or opens the pin in a new tab that it then owns.
  func openPin(_ pin: Favorite) {
    if let id = pinnedTabIDs[pin.id], let tab = snapshot.tabs.first(where: { $0.id == id }) {
      return activate(tab)
    }
    open(pin.url)
    if let id = snapshot.activeTabID { pinTabIDs[pin.id] = id }
  }

  /// Takes the pin's tab back to the pin's own URL.
  func resetPin(_ pin: Favorite) {
    guard let id = pinnedTabIDs[pin.id] else { return }
    perform { (chrome) throws(ChromeError) in try chrome.setURL(tabID: id, url: pin.url) }
    refreshTabs()
  }

  /// Closes the pin's tab. The pin stays.
  func closePinnedTab(_ pin: Favorite) {
    guard let id = pinnedTabIDs[pin.id], let tab = snapshot.tabs.first(where: { $0.id == id }) else { return }
    close(tab)
  }

  private func savePins(_ next: [Favorite]) {
    guard next != pins else { return }
    pins = next
    do {
      try pinsStore.save(next)
    } catch {
      log.error("Pins save failed: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: - Archive

  /// Tabs that Clear and auto-archive keep open.
  private var keptTabIDs: Set<Int> {
    Set(pinnedTabIDs.values).union(favorites.compactMap { $0.matchingTab(in: snapshot.tabs)?.id })
  }

  private func noteActivity(_ next: TabSnapshot) {
    let now = Date()
    for tab in next.tabs where lastActive[tab.id] == nil { lastActive[tab.id] = now }
    if let active = next.activeTabID { lastActive[active] = now }
  }

  /// Closes the tabs that no one has used for `after` seconds and keeps them in the archive.
  func archiveStaleTabs(after: TimeInterval) {
    var keep = keptTabIDs
    if let active = snapshot.activeTabID { keep.insert(active) }
    let ids = AutoArchive.idsToArchive(
      tabs: snapshot.tabs, lastActive: lastActive, keep: keep, after: after, now: Date())
    guard !ids.isEmpty else { return }
    closeAndArchive(ids)
  }

  private func closeAndArchive(_ ids: [Int]) {
    let now = Date()
    let closing = snapshot.tabs.filter { ids.contains($0.id) }
      .map { ArchivedTab(url: $0.url, title: $0.title.isEmpty ? $0.url : $0.title, closedAt: now) }
    closedBySidebar.formUnion(ids)
    perform { (chrome) throws(ChromeError) in try chrome.closeTabs(ids: ids) }
    refreshTabs()
    archived = ArchiveStore.adding(closing, to: archived)
    do {
      try archiveStore.save(archived)
    } catch {
      log.error("Archive save failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Opens an archived tab and takes it out of the archive.
  func restore(url: String) {
    open(url)
    archived.removeAll { $0.url == url }
    try? archiveStore.save(archived)
  }

  // MARK: - Commands

  /// The palette's commands, after `>`.
  var commands: [PaletteCommand] {
    var list = [
      PaletteCommand(id: "clear", title: "Clear Tabs", symbol: "arrow.down.to.line"),
      PaletteCommand(id: "pin", title: "Pin Current Tab", symbol: "pin"),
      PaletteCommand(id: "favorite", title: "Add Current Tab to Favorites", symbol: "star"),
      PaletteCommand(id: "copy", title: "Copy URL", symbol: "link"),
      PaletteCommand(
        id: "collapse", title: isCollapsed ? "Expand Sidebar" : "Collapse Sidebar", symbol: "sidebar.left"),
    ]
    for space in spaces where space.directory != spaceDirectory {
      list.append(PaletteCommand(id: "space:\(space.directory)", title: "Switch to \(space.name)", symbol: "square.stack"))
    }
    list += [
      PaletteCommand(id: "reload", title: "Reload Bookmarks and History", symbol: "arrow.clockwise"),
      PaletteCommand(id: "settings", title: "Open Settings", symbol: "gearshape"),
    ]
    return list
  }

  func run(command id: String) {
    switch id {
    case "clear": clearInactiveTabs()
    case "pin": if let activeTab { pin(activeTab) }
    case "favorite": if let activeTab { addFavorite(activeTab) }
    case "copy": copyURL()
    case "collapse": toggleCollapse()
    case "reload":
      refreshBookmarks()
      refreshRecents()
      refreshTabs()
    case "settings": openSettings()
    default:
      if id.hasPrefix("space:"), let space = spaces.first(where: { "space:\($0.directory)" == id }) {
        switchSpace(space)
      }
    }
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

  /// The tabs that Clear would close.
  var clearableTabIDs: [Int] {
    TabCleanup.idsToClose(
      in: snapshot.tabs, activeID: snapshot.activeTabID, favorites: favorites, keeping: Set(pinnedTabIDs.values))
  }

  /// Arc's "Clear": closes every tab except the active one and the tabs of favorites.
  func clearInactiveTabs() {
    let ids = clearableTabIDs
    guard !ids.isEmpty else { return }
    closeAndArchive(ids)
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
    case .archived:
      restore(url: result.url)
    case let .command(id):
      run(command: id)
    case let .shortcut(id):
      openShortcut(id)
    case .closed:
      reopen(url: result.url)
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
