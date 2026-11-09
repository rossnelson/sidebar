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

  /// The bookmarks bar's contents come first, at the top level, the way the bar shows them.
  /// "Other" and "Mobile" follow as folders, and only when they hold something.
  public static func parse(_ data: Data) throws -> [BookmarkNode] {
    let file = try JSONDecoder().decode(File.self, from: data)
    var result = file.roots["bookmark_bar"]?.node.children ?? []
    for key in ["other", "synced"] {
      if let folder = file.roots[key]?.node, !folder.children.isEmpty {
        result.append(folder)
      }
    }
    return result
  }
}
