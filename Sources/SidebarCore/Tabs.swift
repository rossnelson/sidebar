import Foundation

public struct ChromeTab: Identifiable, Sendable, Equatable {
  /// Chrome's own tab ID. Stable while the tab lives.
  public let id: Int
  public let title: String
  public let url: String

  public init(id: Int, title: String, url: String) {
    self.id = id
    self.title = title
    self.url = url
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

  /// Separators that cannot appear in a title or URL typed by a person.
  public static let recordSeparator = "\u{1E}"
  public static let unitSeparator = "\u{1F}"

  /// Parses the text that `ChromeScripts.frontWindowTabs` returns:
  /// `activeIndex RS id US title US url RS id US title US url ...`.
  /// An empty string means Chrome has no window.
  public static func parse(_ output: String) -> TabSnapshot {
    let records = output.components(separatedBy: recordSeparator)
    guard let first = records.first, let active = Int(first) else { return .empty }
    let tabs = records.dropFirst().compactMap { record -> ChromeTab? in
      let fields = record.components(separatedBy: unitSeparator)
      guard fields.count >= 3, let id = Int(fields[0]) else { return nil }
      // A title could in theory hold a separator; the URL is always the last field.
      let title = fields[1..<(fields.count - 1)].joined(separator: unitSeparator)
      return ChromeTab(id: id, title: title, url: fields[fields.count - 1])
    }
    return TabSnapshot(tabs: tabs, activeIndex: active)
  }
}

/// AppleScript sources for Google Chrome.
public enum ChromeScripts {
  public static let bundleID = "com.google.Chrome"

  /// Three bulk Apple Events (ids, titles, URLs) instead of three per tab.
  public static let frontWindowTabs = """
    tell application id "\(bundleID)"
      if (count of windows) is 0 then return ""
      set w to front window
      set ids to id of tabs of w
      set titles to title of tabs of w
      set urls to URL of tabs of w
      set rs to character id 30
      set us to character id 31
      set out to (active tab index of w) as text
      repeat with i from 1 to count of ids
        set out to out & rs & ((item i of ids) as text) & us & (item i of titles) & us & (item i of urls)
      end repeat
      return out
    end tell
    """

  /// Every tab of every window, for the palette.
  public static let allTabs = """
    tell application id "\(bundleID)"
      set rs to character id 30
      set us to character id 31
      set out to ""
      repeat with w in windows
        set wid to (id of w) as text
        set ids to id of tabs of w
        set titles to title of tabs of w
        set urls to URL of tabs of w
        repeat with i from 1 to count of ids
          set out to out & rs & wid & us & ((item i of ids) as text) & us & (item i of titles) & us & (item i of urls)
        end repeat
      end repeat
      return out
    end tell
    """

  /// Switches to a tab in any window and brings that window to the front.
  // Chrome 157 reports tab IDs as text; older versions as integers. Compare as text.
  public static func activateTab(windowID: Int, tabID: Int) -> String {
    """
    tell application id "\(bundleID)"
      set w to window id \(windowID)
      set i to 0
      repeat with t in tabs of w
        set i to i + 1
        if ((id of t) as text) is "\(tabID)" then
          set active tab index of w to i
          exit repeat
        end if
      end repeat
      set index of w to 1
      activate
    end tell
    """
  }

  public static func activateTab(id: Int) -> String {
    """
    tell application id "\(bundleID)"
      set w to front window
      set i to 0
      repeat with t in tabs of w
        set i to i + 1
        if ((id of t) as text) is "\(id)" then
          set active tab index of w to i
          exit repeat
        end if
      end repeat
    end tell
    """
  }

  public static func closeTab(id: Int) -> String {
    """
    tell application id "\(bundleID)"
      repeat with t in tabs of front window
        if ((id of t) as text) is "\(id)" then
          close t
          exit repeat
        end if
      end repeat
    end tell
    """
  }

  public enum Navigation: String, Sendable { case back = "go back", forward = "go forward", reload }

  public static func navigate(_ navigation: Navigation) -> String {
    """
    tell application id "\(bundleID)"
      if (count of windows) > 0 then tell active tab of front window to \(navigation.rawValue)
    end tell
    """
  }

  /// Opens `url` in a new tab of the front window, or a new window when none is open.
  public static func openInNewTab(_ url: String) -> String {
    """
    tell application id "\(bundleID)"
      if (count of windows) is 0 then
        make new window
        set URL of active tab of front window to "\(escape(url))"
      else
        tell front window to make new tab with properties {URL:"\(escape(url))"}
      end if
    end tell
    """
  }

  /// Escapes a value for use inside an AppleScript string literal.
  public static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: "\r", with: "")
  }
}
