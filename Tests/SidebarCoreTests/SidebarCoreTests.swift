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
