import Foundation

/// Pinned tabs: a space's tabs that stay in the sidebar, like Arc's pinned
/// tabs. A pin keeps its own URL; its open tab can wander and come back.
public enum PinMatching {
  /// Each pin's open tab: the tab it opened or was pinned from while that tab
  /// is still open, else a tab on exactly the pin's URL. A tab serves one pin.
  public static func match(pins: [Favorite], tabs: [ChromeTab], remembered: [UUID: Int]) -> [UUID: Int] {
    let open = Set(tabs.map(\.id))
    var result: [UUID: Int] = [:]
    var used: Set<Int> = []
    for pin in pins {
      if let id = remembered[pin.id], open.contains(id), used.insert(id).inserted { result[pin.id] = id }
    }
    for pin in pins where result[pin.id] == nil {
      if let tab = tabs.first(where: { $0.url == pin.url && !used.contains($0.id) }) {
        result[pin.id] = tab.id
        used.insert(tab.id)
      }
    }
    return result
  }
}

/// A tab that Sidebar closed: by Clear, or by auto-archive after a time unused.
public struct ArchivedTab: Codable, Identifiable, Sendable, Equatable {
  public var id: UUID
  public var url: String
  public var title: String
  public var closedAt: Date

  public init(id: UUID = UUID(), url: String, title: String, closedAt: Date) {
    self.id = id
    self.url = url
    self.title = title
    self.closedAt = closedAt
  }
}

/// The archive of one space, newest first, saved as JSON.
public struct ArchiveStore: Sendable {
  public let file: URL
  public static let limit = 200

  public init(folder: URL, profileDirectory: String) {
    file = folder.appending(path: "archive-\(profileDirectory).json")
  }

  public func load() -> [ArchivedTab] {
    guard let data = try? Data(contentsOf: file) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([ArchivedTab].self, from: data)) ?? []
  }

  public func save(_ tabs: [ArchivedTab]) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(tabs).write(to: file, options: .atomic)
  }

  /// Puts new tabs first. An older entry with the same URL goes; the oldest
  /// entries go past the limit. Chrome's own pages are not kept.
  public static func adding(_ new: [ArchivedTab], to archive: [ArchivedTab]) -> [ArchivedTab] {
    var seen: Set<String> = []
    let kept = (new + archive).filter {
      !$0.url.hasPrefix("chrome://") && !$0.url.isEmpty && seen.insert($0.url).inserted
    }
    return Array(kept.prefix(limit))
  }
}

/// Arc's auto-archive: tabs unused for a set time close by themselves.
public enum AutoArchive {
  /// The tabs not active since `now - after`. Tabs in `keep` (the active tab,
  /// pinned tabs, the tabs of favorites) and tabs with no time yet stay open.
  public static func idsToArchive(
    tabs: [ChromeTab], lastActive: [Int: Date], keep: Set<Int>, after: TimeInterval, now: Date
  ) -> [Int] {
    guard after > 0 else { return [] }
    return tabs.compactMap { tab in
      guard !keep.contains(tab.id), let last = lastActive[tab.id], now.timeIntervalSince(last) >= after else {
        return nil
      }
      return tab.id
    }
  }
}
