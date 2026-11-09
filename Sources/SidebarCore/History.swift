import Foundation
import SQLite3

public struct HistoryItem: Identifiable, Sendable, Equatable {
  public let id: Int64
  public let title: String
  public let url: String
  public let lastVisit: Date

  public init(id: Int64, title: String, url: String, lastVisit: Date) {
    self.id = id
    self.title = title
    self.url = url
    self.lastVisit = lastVisit
  }
}

public enum HistoryError: Error, Equatable {
  case open(String)
  case query(String)
}

/// Reads recent pages from Chrome's `History` SQLite database.
///
/// Chrome keeps the live file locked, so this reads a private copy.
public enum ChromeHistory {
  /// Chrome stores times as microseconds since 1601-01-01 UTC.
  public static func date(fromChromeTime microseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
  }

  public static func recent(historyFile: URL, limit: Int = 30) throws -> [HistoryItem] {
    let copy = FileManager.default.temporaryDirectory
      .appending(path: "sidebar-history-\(UUID().uuidString).sqlite")
    try FileManager.default.copyItem(at: historyFile, to: copy)
    defer { try? FileManager.default.removeItem(at: copy) }
    return try query(databaseFile: copy, limit: limit)
  }

  public static func query(databaseFile: URL, limit: Int) throws -> [HistoryItem] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databaseFile.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      sqlite3_close(db)
      throw HistoryError.open(message)
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT id, url, title, last_visit_time FROM urls
      WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')
      ORDER BY last_visit_time DESC LIMIT ?
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw HistoryError.query(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int(statement, 1, Int32(limit))

    var items: [HistoryItem] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let url = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
      let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
      items.append(HistoryItem(
        id: sqlite3_column_int64(statement, 0),
        title: title.isEmpty ? url : title,
        url: url,
        lastVisit: date(fromChromeTime: sqlite3_column_int64(statement, 3))
      ))
    }
    return items
  }
}
