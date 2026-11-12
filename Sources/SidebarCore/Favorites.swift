import Foundation

/// A favorite tile in a space's grid.
public struct Favorite: Codable, Identifiable, Sendable, Equatable {
  public var id: UUID
  public var url: String
  public var title: String

  public init(id: UUID = UUID(), url: String, title: String) {
    self.id = id
    self.url = url
    self.title = title
  }

  var host: String? {
    URL(string: url)?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
  }

  /// The open tab this favorite stands for: the same URL, else the first tab on the same site.
  public func matchingTab(in tabs: [ChromeTab]) -> ChromeTab? {
    if let exact = tabs.first(where: { $0.url == url }) { return exact }
    guard let host else { return nil }
    return tabs.first { Favorite(url: $0.url, title: "").host == host }
  }
}

/// The favorites of one space (Chrome profile), saved as JSON.
public struct FavoritesStore: Sendable {
  public let file: URL
  public static let capacity = 12

  public init(file: URL) {
    self.file = file
  }

  /// One file per profile folder, for example `favorites-Profile 1.json`.
  public init(folder: URL, profileDirectory: String) {
    self.init(file: folder.appending(path: "favorites-\(profileDirectory).json"))
  }

  public func load() -> [Favorite] {
    guard let data = try? Data(contentsOf: file) else { return [] }
    return (try? JSONDecoder().decode([Favorite].self, from: data)) ?? []
  }

  public func save(_ favorites: [Favorite]) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(favorites).write(to: file, options: .atomic)
  }

  public static let columns = 4

  /// Tiles to draw: the favorites plus empty slots to finish their last row.
  /// One row at least, so an empty space still shows where favorites go.
  public static func slotCount(for favoriteCount: Int) -> Int {
    let rows = max(1, (favoriteCount + columns - 1) / columns)
    return min(rows * columns, capacity)
  }

  /// Adds a favorite unless the URL is already there or the grid is full.
  public static func adding(_ favorite: Favorite, to favorites: [Favorite]) -> [Favorite] {
    guard favorites.count < capacity, !favorites.contains(where: { $0.url == favorite.url }) else {
      return favorites
    }
    return favorites + [favorite]
  }

  /// Moves a favorite to the place of `target`, or to the end when `target` is `nil`.
  /// Dropping a favorite on itself changes nothing.
  public static func moving(_ id: UUID, to target: UUID?, in favorites: [Favorite]) -> [Favorite] {
    guard id != target, let from = favorites.firstIndex(where: { $0.id == id }) else { return favorites }
    var next = favorites
    let moved = next.remove(at: from)
    guard let target, let to = favorites.firstIndex(where: { $0.id == target }) else {
      return next + [moved]
    }
    // Moving right puts the favorite after the target; moving left, before it.
    next.insert(moved, at: to)
    return next
  }
}

/// Arc's "Clear": the tabs to close, which are all but the active tab and
/// the tabs that favorites stand for.
public enum TabCleanup {
  public static func idsToClose(in tabs: [ChromeTab], activeID: Int?, favorites: [Favorite]) -> [Int] {
    let kept = Set(favorites.compactMap { $0.matchingTab(in: tabs)?.id } + [activeID].compactMap { $0 })
    return tabs.map(\.id).filter { !kept.contains($0) }
  }
}
