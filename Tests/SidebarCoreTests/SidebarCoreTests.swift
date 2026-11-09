import CoreGraphics
import Foundation
import Testing
@testable import SidebarCore

@Suite struct TabParsing {
  @Test func `parses the active index and every tab`() {
    let rs = TabSnapshot.recordSeparator, us = TabSnapshot.unitSeparator
    let output = "2\(rs)11\(us)Inbox\(us)https://mail.google.com\(rs)12\(us)Docs\(us)https://docs.google.com"
    let snapshot = TabSnapshot.parse(output)
    #expect(snapshot.activeIndex == 2)
    #expect(snapshot.tabs == [
      ChromeTab(id: 11, title: "Inbox", url: "https://mail.google.com"),
      ChromeTab(id: 12, title: "Docs", url: "https://docs.google.com"),
    ])
    #expect(snapshot.activeTabID == 12)
  }

  @Test func `empty output means no window`() {
    #expect(TabSnapshot.parse("") == .empty)
  }

  @Test func `keeps a title that holds a separator`() {
    let rs = TabSnapshot.recordSeparator, us = TabSnapshot.unitSeparator
    let snapshot = TabSnapshot.parse("1\(rs)5\(us)a\(us)b\(us)https://x.com")
    #expect(snapshot.tabs.first?.title == "a\(us)b")
    #expect(snapshot.tabs.first?.url == "https://x.com")
  }

  @Test func `escapes quotes and backslashes for AppleScript`() {
    #expect(ChromeScripts.escape(#"https://a.com/?q="x"\y"#) == #"https://a.com/?q=\"x\"\\y"#)
  }
}

@Suite struct BookmarkParsing {
  @Test func `bar items are top level and other is a folder`() throws {
    let json = """
      {"roots": {
        "bookmark_bar": {"id": "1", "name": "Bookmarks bar", "type": "folder", "children": [
          {"id": "3", "name": "GitHub", "type": "url", "url": "https://github.com"},
          {"id": "4", "name": "Work", "type": "folder", "children": [
            {"id": "5", "name": "Jira", "type": "url", "url": "https://jira.example.com"}]}]},
        "other": {"id": "2", "name": "Other bookmarks", "type": "folder", "children": [
          {"id": "6", "name": "News", "type": "url", "url": "https://news.ycombinator.com"}]},
        "synced": {"id": "7", "name": "Mobile bookmarks", "type": "folder", "children": []}
      }}
      """
    let nodes = try ChromeBookmarks.parse(Data(json.utf8))
    #expect(nodes.map(\.title) == ["GitHub", "Work", "Other bookmarks"])
    #expect(nodes[1].isFolder)
    #expect(nodes.flatMap(\.allLinks).map(\.title) == ["GitHub", "Jira", "News"])
  }
}

@Suite struct ProfileLookup {
  @Test func `reads last used profile`() {
    let data = Data(#"{"profile": {"last_used": "Profile 1"}}"#.utf8)
    #expect(ChromeProfile.lastUsedName(localState: data) == "Profile 1")
  }

  @Test(arguments: [nil, Data("{}".utf8), Data("not json".utf8)])
  func `falls back to Default`(data: Data?) {
    #expect(ChromeProfile.lastUsedName(localState: data) == "Default")
  }
}

@Suite struct HistoryTime {
  @Test func `converts Chrome time to a Date`() {
    // 2021-01-01T00:00:00Z
    let chrome: Int64 = (1_609_459_200 + 11_644_473_600) * 1_000_000
    #expect(ChromeHistory.date(fromChromeTime: chrome) == Date(timeIntervalSince1970: 1_609_459_200))
  }
}

@Suite struct Rules {
  let browser = WindowAttributes(role: "AXWindow", subrole: "AXStandardWindow", size: CGSize(width: 1200, height: 800))

  @Test func `accepts a normal browser window`() {
    #expect(WindowRules.isAttachable(browser))
  }

  @Test(arguments: ["AXDialog", "AXSheet", "AXFloatingWindow", "AXPopover", "AXSystemDialog"])
  func `rejects dialogs and popovers`(subrole: String) {
    var window = browser
    window.subrole = subrole
    #expect(!WindowRules.isAttachable(window))
  }

  @Test func `rejects devtools, modal, minimized, full screen and small windows`() {
    var devtools = browser; devtools.document = "devtools://devtools/bundled/inspector.html"
    var modal = browser; modal.isModal = true
    var minimized = browser; minimized.isMinimized = true
    var fullScreen = browser; fullScreen.isFullScreen = true
    var small = browser; small.size = CGSize(width: 300, height: 200)
    for window in [devtools, modal, minimized, fullScreen, small] {
      #expect(!WindowRules.isAttachable(window))
    }
  }
}

@Suite struct Layout {
  let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)

  @Test func `sits left of the window when there is room`() {
    let window = CGRect(x: 400, y: 100, width: 1000, height: 800)
    let layout = AttachLayout.compute(window: window, screen: screen, sidebarWidth: 260)
    #expect(layout.panel == CGRect(x: 140, y: 100, width: 260, height: 800))
    #expect(layout.windowFrame == nil)
  }

  @Test func `pushes a window at the screen edge to the right`() {
    let window = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    let layout = AttachLayout.compute(window: window, screen: screen, sidebarWidth: 260)
    #expect(layout.windowFrame == CGRect(x: 260, y: 0, width: 1468, height: 1080))
    #expect(layout.panel == CGRect(x: 0, y: 0, width: 260, height: 1080))
  }

  @Test func `flips between Accessibility and Cocoa coordinates`() {
    let ax = CGRect(x: 10, y: 20, width: 100, height: 50)
    let cocoa = ScreenCoordinates.flip(ax, primaryScreenHeight: 1000)
    #expect(cocoa == CGRect(x: 10, y: 930, width: 100, height: 50))
    #expect(ScreenCoordinates.flip(cocoa, primaryScreenHeight: 1000) == ax)
  }
}

@Suite struct PaletteRanking {
  let tabs = [
    WindowTab(windowID: 1, tab: ChromeTab(id: 10, title: "Inbox (3) - Gmail", url: "https://mail.google.com/mail/u/0/")),
    WindowTab(windowID: 2, tab: ChromeTab(id: 20, title: "temporalio/ui: Pull requests", url: "https://github.com/temporalio/ui/pulls")),
  ]
  let bookmarks = [
    BookmarkNode(id: "b1", title: "GitHub", url: "https://github.com/temporalio/ui/pulls"),
    BookmarkNode(id: "b2", title: "Hacker News", url: "https://news.ycombinator.com/"),
  ]
  let history = [
    HistoryItem(id: 1, title: "Swift Testing docs", url: "https://developer.apple.com/documentation/testing", lastVisit: .now),
  ]

  func titles(_ query: String) -> [String] {
    PaletteSearch.results(query: query, tabs: tabs, bookmarks: bookmarks, history: history).map(\.title)
  }

  @Test func `an open tab ranks first and hides the same bookmark`() {
    let results = PaletteSearch.results(query: "pull", tabs: tabs, bookmarks: bookmarks, history: history)
    #expect(results.first?.kind == .tab(windowID: 2, tabID: 20))
    #expect(!results.contains { $0.id == "bookmark-b1" })
  }

  @Test func `matches the host and fuzzy text`() {
    #expect(titles("ycomb").first == "Hacker News")
    #expect(titles("hknws").first == "Hacker News")
  }

  @Test func `every word must match`() {
    #expect(titles("swift docs").first == "Swift Testing docs")
    #expect(!titles("swift gmail").contains("Swift Testing docs"))
  }

  @Test func `search is always last and a URL comes first`() {
    let results = PaletteSearch.results(query: "example.com", tabs: tabs, bookmarks: bookmarks, history: history)
    #expect(results.first?.kind == .url)
    #expect(results.first?.url == "https://example.com")
    #expect(results.last?.kind == .search)
  }

  @Test func `empty query lists tabs then history`() {
    #expect(titles("") == ["Inbox (3) - Gmail", "temporalio/ui: Pull requests", "Swift Testing docs"])
  }

  @Test(arguments: [
    ("github.com", true), ("localhost:3000", true), ("https://a", true),
    ("swift testing", false), ("v1.2", false), (".com", false), ("hello", false),
  ])
  func `detects URLs`(text: String, expected: Bool) {
    #expect(Destination.looksLikeURL(text) == expected)
  }

  @Test func `parses tabs from every window`() {
    let rs = TabSnapshot.recordSeparator, us = TabSnapshot.unitSeparator
    let parsed = WindowTab.parseAll("\(rs)7\(us)1\(us)A\(us)https://a.com\(rs)8\(us)2\(us)B\(us)https://b.com")
    #expect(parsed.map(\.windowID) == [7, 8])
    #expect(parsed.map(\.tab.title) == ["A", "B"])
  }
}

@Suite struct ScriptShape {
  // Chrome 157 returns tab IDs as text, so an integer comparison never matches.
  @Test func `tab scripts compare IDs as text`() {
    for script in [
      ChromeScripts.activateTab(id: 42), ChromeScripts.closeTab(id: 42),
      ChromeScripts.activateTab(windowID: 1, tabID: 42),
    ] {
      #expect(script.contains(#"((id of t) as text) is "42""#))
    }
  }
}

@Suite struct ProfileThemes {
  let profiles = [
    ProfileInfo(directory: "Default", name: "Your Chrome", isUsingDefaultName: true, givenName: "Ross"),
    ProfileInfo(directory: "Profile 1", name: "Work", isUsingDefaultName: false, givenName: "Ross"),
    ProfileInfo(directory: "Profile 2", name: "Temporal", isUsingDefaultName: false, givenName: "Ross"),
  ]

  @Test(arguments: [
    ("Claude Code - Google Chrome - Ross (Work)", "Profile 1"),
    ("New Tab - Google Chrome - Ross (Temporal)", "Profile 2"),
    ("Retro Cable Box - Google Chrome - Ross", "Default"),
    ("A - Google Chrome - B - Google Chrome - Ross (Work)", "Profile 1"),
  ])
  func `finds the profile from the window title`(title: String, directory: String) {
    #expect(ChromeProfiles.directory(forWindowTitle: title, profiles: profiles) == directory)
  }

  @Test func `no Chrome marker means unknown`() {
    #expect(ChromeProfiles.directory(forWindowTitle: "Settings", profiles: profiles) == nil)
  }

  @Test func `parses Local State profiles`() {
    let json = #"{"profile": {"info_cache": {"Profile 1": {"name": "Work", "is_using_default_name": false, "gaia_given_name": "Ross"}}}}"#
    #expect(ChromeProfiles.parse(localState: Data(json.utf8)) == [profiles[1]])
  }

  @Test func `reads the seed color and scheme`() {
    let json = #"{"browser": {"theme": {"user_color": -14244198, "color_scheme2": 2}}}"#
    let theme = ProfileTheme.parse(preferences: Data(json.utf8))
    #expect(theme.seed == 0x26A69A)
    #expect(theme.scheme == .dark)
  }

  @Test func `no theme block is Chrome's default`() {
    #expect(ProfileTheme.parse(preferences: Data("{}".utf8)) == .standard)
  }

  @Test(arguments: [0x26A69A, 0x7200FF, 0x8CABE4, 0x000000, 0xFFFFFF] as [UInt32])
  func `LCh round-trips sRGB`(hex: UInt32) {
    #expect(LCh(rgb: RGB(hex: hex)).rgb.hex == hex)
  }

  @Test func `palette keeps the seed hue and the requested lightness`() {
    let seedHue = LCh(rgb: RGB(hex: 0x26A69A)).h
    let palette = ThemePalette.make(seed: 0x26A69A, dark: true)
    let background = LCh(rgb: palette.background)
    #expect(abs(background.l - 14) < 1)
    #expect(abs(background.h - seedHue) < 3)
    #expect(LCh(rgb: palette.text).l > 90)
    let gray = LCh(rgb: ThemePalette.make(seed: 0x26A69A, dark: true, grayscale: true).background)
    #expect(gray.c < 1)
  }
}

@Suite struct ArcFrame {
  let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)

  @Test func `leaves a window that already fits`() {
    let window = CGRect(x: 400, y: 100, width: 1000, height: 800)
    let layout = FrameLayout.compute(window: window, screen: screen, sidebarWidth: 260, margin: 8)
    #expect(layout.windowFrame == nil)
    #expect(layout.frame == CGRect(x: 140, y: 92, width: 1268, height: 816))
    #expect(layout.holeInFrame == CGRect(x: 260, y: 8, width: 1000, height: 800))
  }

  @Test func `insets a maximized window on every side`() {
    let layout = FrameLayout.compute(window: screen, screen: screen, sidebarWidth: 260, margin: 8)
    #expect(layout.windowFrame == CGRect(x: 260, y: 8, width: 1460, height: 1064))
    #expect(layout.frame == screen)
  }

  @Test func `vivid gradient keeps the seed hue`() {
    let hue = LCh(rgb: RGB(hex: 0xE040A0)).h
    let palette = SpacePalette.make(seed: 0xE040A0, dark: false)
    let start = LCh(rgb: palette.gradientStart), end = LCh(rgb: palette.gradientEnd)
    #expect(abs(((start.h + end.h) / 2) - hue) < 6)
    #expect(start.l > end.l)
  }
}

@Suite struct Favorites {
  let tabs = [
    ChromeTab(id: 1, title: "Inbox", url: "https://mail.google.com/mail/u/0/#inbox"),
    ChromeTab(id: 2, title: "PRs", url: "https://www.github.com/pulls"),
  ]

  @Test func `matches the exact URL first, then the site`() {
    #expect(Favorite(url: "https://www.github.com/pulls", title: "").matchingTab(in: tabs)?.id == 2)
    #expect(Favorite(url: "https://github.com/", title: "").matchingTab(in: tabs)?.id == 2)
    #expect(Favorite(url: "https://mail.google.com/", title: "").matchingTab(in: tabs)?.id == 1)
    #expect(Favorite(url: "https://news.ycombinator.com/", title: "").matchingTab(in: tabs) == nil)
  }

  @Test func `saves and loads one file per profile`() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let work = FavoritesStore(folder: folder, profileDirectory: "Profile 1")
    let favorites = [Favorite(url: "https://github.com", title: "GitHub")]
    try work.save(favorites)
    #expect(work.load() == favorites)
    #expect(FavoritesStore(folder: folder, profileDirectory: "Profile 2").load().isEmpty)
  }

  @Test func `adding skips duplicates and stops at capacity`() {
    let one = Favorite(url: "https://a.com", title: "A")
    #expect(FavoritesStore.adding(one, to: [one]).count == 1)
    let full = (0..<FavoritesStore.capacity).map { Favorite(url: "https://\($0).com", title: "") }
    #expect(FavoritesStore.adding(one, to: full).count == FavoritesStore.capacity)
  }

  @Test func `navigation scripts target the active tab`() {
    #expect(ChromeScripts.navigate(.back).contains("tell active tab of front window to go back"))
    #expect(ChromeScripts.navigate(.reload).contains("to reload"))
  }
}

@Suite struct FrameStability {
  let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)

  @Test func `a window a few points off does not move`() {
    // Where the last correction put it, give or take Chrome's settling.
    let settled = CGRect(x: 258, y: 6, width: 1464, height: 1068)
    let layout = FrameLayout.compute(window: settled, screen: screen, sidebarWidth: 260, margin: 8)
    #expect(layout.windowFrame == nil)
  }

  @Test func `repeated layouts converge after one correction`() {
    var window = screen
    var corrections = 0
    for _ in 0..<20 {
      let layout = FrameLayout.compute(window: window, screen: screen, sidebarWidth: 260, margin: 8)
      guard let moved = layout.windowFrame else { break }
      corrections += 1
      // Chrome settles one point up and one point wider than asked.
      window = moved.offsetBy(dx: 0, dy: 1).insetBy(dx: -0.5, dy: 0)
    }
    #expect(corrections == 1)
    #expect(window.height > 1000)
  }
}

@Suite struct BookmarkMerging {
  func file(bar: [String], other: [String] = []) -> Data {
    func links(_ names: [String]) -> String {
      names.map { #"{"id": "\#($0)", "name": "\#($0)", "type": "url", "url": "https://\#($0).com"}"# }
        .joined(separator: ",")
    }
    return Data("""
      {"roots": {
        "bookmark_bar": {"id": "1", "name": "Bar", "type": "folder", "children": [\(links(bar))]},
        "other": {"id": "2", "name": "Other bookmarks", "type": "folder", "children": [\(links(other))]}
      }}
      """.utf8)
  }

  @Test func `account bookmarks come first, then local ones, with one Other folder`() throws {
    let account = file(bar: ["Claude", "VG"], other: ["a"])
    let local = file(bar: ["local"], other: ["b"])
    let nodes = try ChromeBookmarks.parse([account, local])
    #expect(nodes.map(\.title) == ["Claude", "VG", "local", "Other bookmarks"])
    #expect(nodes.last?.children.map(\.title) == ["a", "b"])
  }

  @Test func `an empty local file adds nothing`() throws {
    let nodes = try ChromeBookmarks.parse([file(bar: ["Claude"]), file(bar: [])])
    #expect(nodes.map(\.title) == ["Claude"])
  }
}

extension BookmarkMerging {
  @Test func `IDs stay unique across files`() throws {
    let nodes = try ChromeBookmarks.parse([file(bar: ["x"]), file(bar: ["x"])])
    #expect(Set(nodes.map(\.id)).count == nodes.count)
  }
}

extension Favorites {
  @Test(arguments: [(0, 4), (1, 4), (4, 4), (5, 8), (8, 8), (9, 12), (12, 12)])
  func `adds a row only when a favorite needs it`(count: Int, slots: Int) {
    #expect(FavoritesStore.slotCount(for: count) == slots)
  }
}

private typealias M = KeyRouting.Modifiers

@Suite struct PaletteKeys {
  typealias K = KeyRouting.Key
  let cmd = M.command

  @Test(arguments: [
    (K.w, M.command),
    (K.t, M([.command, .shift])),
    (18, M.command),  // ⌘1
    (25, M.command),  // ⌘9
    (15, M.command),  // ⌘R
    (33, M.command),  // ⌘[
    (K.tab, M.control),
    (K.tab, M([.control, .shift])),
    (K.right, M([.command, .option])),
  ] as [(UInt16, M)])
  func `Chrome's tab keys pass through`(key: UInt16, modifiers: KeyRouting.Modifiers) {
    #expect(KeyRouting.forwardsToChrome(keyCode: key, modifiers: modifiers))
  }

  @Test(arguments: [
    (K.t, M.command),  // the palette's own ⌘T
    (K.a, M.command), (K.c, M.command), (K.v, M.command), (K.z, M([.command, .shift])),
    (K.left, M.command), (K.delete, M.command),
    (K.q, M.command), (K.h, M.command), (K.m, M.command),
    (K.a, M.control),  // ⌃A: start of line
    (45, M.control),  // ⌃N: next result
    (K.w, M()),  // typing "w"
  ] as [(UInt16, M)])
  func `the palette keeps typing, editing and app keys`(key: UInt16, modifiers: KeyRouting.Modifiers) {
    #expect(!KeyRouting.forwardsToChrome(keyCode: key, modifiers: modifiers))
  }
}
