import Foundation
import SQLite3

/// Favicons from Chrome's own cache (`<profile>/Favicons`), so private and
/// local sites get their real icons and no site is sent to a favicon service.
public struct FaviconIndex: Sendable {
  /// PNG data by exact page URL.
  public var byPage: [String: Data]
  /// PNG data by host without `www.`, from the first page seen on that host.
  public var byHost: [String: Data]

  public init(byPage: [String: Data] = [:], byHost: [String: Data] = [:]) {
    self.byPage = byPage
    self.byHost = byHost
  }

  /// The icon for a page: its own, else one from the same site.
  public func icon(for url: String) -> Data? {
    if let data = byPage[url] { return data }
    return Self.host(of: url).flatMap { byHost[$0] }
  }

  public static func host(of url: String) -> String? {
    guard let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  /// Reads a private copy of the live file, which Chrome keeps locked.
  public static func load(faviconsFile: URL) throws -> FaviconIndex {
    let copy = FileManager.default.temporaryDirectory
      .appending(path: "sidebar-favicons-\(UUID().uuidString).sqlite")
    try FileManager.default.copyItem(at: faviconsFile, to: copy)
    defer { try? FileManager.default.removeItem(at: copy) }
    return try query(databaseFile: copy)
  }

  /// Keeps one bitmap per page: the smallest one at least 32 px wide, else the largest.
  public static func query(databaseFile: URL) throws -> FaviconIndex {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databaseFile.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      sqlite3_close(db)
      throw HistoryError.open(message)
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT m.page_url, b.width, b.image_data FROM icon_mapping m
      JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
      WHERE b.image_data IS NOT NULL AND length(b.image_data) > 0
      ORDER BY m.id DESC
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw HistoryError.query(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    var best: [String: (width: Int32, data: Data)] = [:]
    var hostOrder: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let text = sqlite3_column_text(statement, 0), let blob = sqlite3_column_blob(statement, 2) else {
        continue
      }
      let page = String(cString: text)
      let width = sqlite3_column_int(statement, 1)
      let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
      if let current = best[page], !isBetter(width, than: current.width) { continue }
      if best[page] == nil { hostOrder.append(page) }
      best[page] = (width, data)
    }

    var index = FaviconIndex()
    // Rows come newest first, so the first page on a host is its most recent.
    for page in hostOrder {
      guard let entry = best[page] else { continue }
      index.byPage[page] = entry.data
      if let host = host(of: page), index.byHost[host] == nil { index.byHost[host] = entry.data }
    }
    return index
  }

  static func isBetter(_ width: Int32, than current: Int32) -> Bool {
    switch (width >= 32, current >= 32) {
    case (true, true): width < current
    case (true, false): true
    case (false, true): false
    case (false, false): width > current
    }
  }
}
