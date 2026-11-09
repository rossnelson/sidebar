import Foundation

/// A tab in any Chrome window.
public struct WindowTab: Sendable, Equatable {
  public let windowID: Int
  public let tab: ChromeTab

  public init(windowID: Int, tab: ChromeTab) {
    self.windowID = windowID
    self.tab = tab
  }

  /// Parses `ChromeScripts.allTabs`: records of `windowID US tabID US title US url`.
  public static func parseAll(_ output: String) -> [WindowTab] {
    output.components(separatedBy: TabSnapshot.recordSeparator).compactMap { record in
      let fields = record.components(separatedBy: TabSnapshot.unitSeparator)
      guard fields.count >= 4, let windowID = Int(fields[0]), let tabID = Int(fields[1]) else {
        return nil
      }
      let title = fields[2..<(fields.count - 1)].joined(separator: TabSnapshot.unitSeparator)
      return WindowTab(windowID: windowID, tab: ChromeTab(id: tabID, title: title, url: fields[fields.count - 1]))
    }
  }
}

/// One row in the Cmd+T palette.
public struct PaletteResult: Identifiable, Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case tab(windowID: Int, tabID: Int)
    case bookmark
    case history
    case url
    case search
  }

  public let id: String
  public let kind: Kind
  public let title: String
  /// The page URL, or for `.search` the search URL.
  public let url: String

  public init(id: String, kind: Kind, title: String, url: String) {
    self.id = id
    self.kind = kind
    self.title = title
    self.url = url
  }
}

/// Turns typed text into a URL to open: a URL as typed, a bare domain with
/// https added, or a Google search.
public enum Destination {
  public static func looksLikeURL(_ text: String) -> Bool {
    let text = text.trimmingCharacters(in: .whitespaces)
    if text.contains(" ") || text.isEmpty { return false }
    if text.contains("://") || text.hasPrefix("localhost") { return true }
    // Host is everything before the first "/" or ":".
    let host = text.prefix { $0 != "/" && $0 != ":" }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return false }
    let isIPv4 = labels.count == 4 && labels.allSatisfy { $0.allSatisfy(\.isNumber) }
    let tld = labels[labels.count - 1]
    return isIPv4 || (tld.count >= 2 && tld.allSatisfy(\.isLetter))
  }

  public static func url(for text: String) -> String {
    let text = text.trimmingCharacters(in: .whitespaces)
    if text.contains("://") { return text }
    if looksLikeURL(text) { return text.hasPrefix("localhost") ? "http://\(text)" : "https://\(text)" }
    return searchURL(for: text)
  }

  public static func searchURL(for text: String) -> String {
    var components = URLComponents(string: "https://www.google.com/search")!
    components.queryItems = [URLQueryItem(name: "q", value: text)]
    return components.url!.absoluteString
  }
}

/// Ranks tabs, bookmarks and history against the typed text.
public enum PaletteSearch {
  /// How well `query` matches `text`. Higher is better; `nil` is no match.
  public static func score(_ query: String, in text: String) -> Int? {
    let q = query.lowercased()
    let t = text.lowercased()
    guard !q.isEmpty, !t.isEmpty else { return nil }
    if t == q { return 1000 }
    if t.hasPrefix(q) { return 800 }
    if let range = t.range(of: q) {
      let atWordStart = range.lowerBound == t.startIndex
        || !t[t.index(before: range.lowerBound)].isLetter
      return atWordStart ? 600 : 400
    }
    // Fuzzy: every query character in order. Tighter spans score higher.
    var index = t.startIndex
    var first: String.Index?
    for character in q where character != " " {
      guard let found = t[index...].firstIndex(of: character) else { return nil }
      if first == nil { first = found }
      index = t.index(after: found)
    }
    guard let first else { return nil }
    let span = t.distance(from: first, to: index)
    return max(1, 200 - (span - q.count) * 5)
  }

  /// Host without `www.`, then path: the part of a URL worth matching.
  static func matchableURL(_ url: String) -> String {
    guard let components = URLComponents(string: url), let host = components.host else { return url }
    let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return bare + components.path
  }

  static func bestScore(_ query: String, title: String, url: String) -> Int? {
    let words = query.split(separator: " ").map(String.init)
    // Every word must match the title or the URL.
    var total = 0
    for word in words {
      let best = [score(word, in: title), score(word, in: matchableURL(url)).map { $0 * 4 / 5 }]
        .compactMap { $0 }.max()
      guard let best else { return nil }
      total += best
    }
    return words.isEmpty ? nil : total / words.count
  }

  public static func results(
    query: String,
    tabs: [WindowTab],
    bookmarks: [BookmarkNode],
    history: [HistoryItem],
    limit: Int = 12
  ) -> [PaletteResult] {
    let text = query.trimmingCharacters(in: .whitespaces)

    let tabResults = tabs.map {
      PaletteResult(
        id: "tab-\($0.tab.id)", kind: .tab(windowID: $0.windowID, tabID: $0.tab.id),
        title: $0.tab.title.isEmpty ? $0.tab.url : $0.tab.title, url: $0.tab.url)
    }
    let bookmarkResults = bookmarks.flatMap(\.allLinks).map {
      PaletteResult(id: "bookmark-\($0.id)", kind: .bookmark, title: $0.title, url: $0.url ?? "")
    }
    let historyResults = history.map {
      PaletteResult(id: "history-\($0.id)", kind: .history, title: $0.title, url: $0.url)
    }

    guard !text.isEmpty else {
      return Array(dedupe(tabResults + historyResults).prefix(limit))
    }

    let boost: (PaletteResult.Kind) -> Int = {
      switch $0 {
      case .tab: 150
      case .bookmark: 100
      default: 0
      }
    }
    var scored: [(result: PaletteResult, score: Int, order: Int)] = []
    for (order, result) in (tabResults + bookmarkResults + historyResults).enumerated() {
      if let score = bestScore(text, title: result.title, url: result.url) {
        scored.append((result, score + boost(result.kind), order))
      }
    }
    scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
    var ranked = Array(dedupe(scored.map(\.result)).prefix(limit))

    let search = PaletteResult(
      id: "search", kind: .search, title: "Search Google for “\(text)”",
      url: Destination.searchURL(for: text))
    if Destination.looksLikeURL(text) {
      let url = Destination.url(for: text)
      ranked.insert(PaletteResult(id: "url", kind: .url, title: "Open \(url)", url: url), at: 0)
    }
    ranked.append(search)
    return ranked
  }

  /// Keeps the first result for each URL, so an open tab hides the same bookmark or history page.
  static func dedupe(_ results: [PaletteResult]) -> [PaletteResult] {
    var seen: Set<String> = []
    return results.filter { seen.insert($0.url).inserted }
  }
}
