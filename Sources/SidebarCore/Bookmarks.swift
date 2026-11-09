import Foundation

/// One node of Chrome's bookmark tree: a folder (with children) or a link.
public struct BookmarkNode: Identifiable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let url: String?
  public let children: [BookmarkNode]

  public var isFolder: Bool { url == nil }

  public init(id: String, title: String, url: String?, children: [BookmarkNode] = []) {
    self.id = id
    self.title = title
    self.url = url
    self.children = children
  }

  func prefixingIDs(with prefix: String) -> BookmarkNode {
    BookmarkNode(id: prefix + id, title: title, url: url, children: children.map { $0.prefixingIDs(with: prefix) })
  }

  /// Every link below this node, depth first.
  public var allLinks: [BookmarkNode] {
    isFolder ? children.flatMap(\.allLinks) : [self]
  }
}

/// Reads the JSON file Chrome keeps at `<profile>/Bookmarks`.
public enum ChromeBookmarks {
  private struct File: Decodable {
    let roots: [String: RawNode]
  }

  private struct RawNode: Decodable {
    let id: String
    let name: String
    let type: String
    let url: String?
    let children: [RawNode]?

    var node: BookmarkNode {
      BookmarkNode(
        id: id,
        title: name,
        url: type == "url" ? url : nil,
        children: (children ?? []).map(\.node)
      )
    }
  }

  /// Files to read in a profile folder, in display order. A signed-in profile
  /// keeps its synced bookmarks in `AccountBookmarks`; `Bookmarks` holds the
  /// ones saved only on this Mac. Both use the same JSON format.
  public static let fileNames = ["AccountBookmarks", "Bookmarks"]

  /// The bookmarks bar's contents come first, at the top level, the way the bar shows them.
  /// "Other" and "Mobile" follow as folders, and only when they hold something.
  public static func parse(_ data: Data) throws -> [BookmarkNode] {
    try parse([data])
  }

  /// Merges several bookmark files: every file's bar items, then one "Other"
  /// and one "Mobile" folder holding every file's items.
  public static func parse(_ files: [Data]) throws -> [BookmarkNode] {
    // Each file numbers its nodes from 1, so prefix IDs with the file's index.
    let decoded = try files.enumerated().map { index, data in
      try JSONDecoder().decode(File.self, from: data).roots.mapValues { $0.node.prefixingIDs(with: "\(index)-") }
    }
    var result = decoded.flatMap { $0["bookmark_bar"]?.children ?? [] }
    for key in ["other", "synced"] {
      let folders = decoded.compactMap { $0[key] }
      let children = folders.flatMap(\.children)
      if let first = folders.first, !children.isEmpty {
        result.append(BookmarkNode(id: first.id, title: first.title, url: nil, children: children))
      }
    }
    return result
  }
}
