import Foundation

/// Finds the Chrome profile folder whose files we read.
public enum ChromeProfile {
  public static var defaultBase: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Google/Chrome")
  }

  /// The profile Chrome used last, from `Local State`. Falls back to `Default`.
  public static func lastUsedDirectory(base: URL = defaultBase) -> URL {
    base.appending(path: lastUsedName(localState: try? Data(contentsOf: base.appending(path: "Local State"))))
  }

  public static func lastUsedName(localState: Data?) -> String {
    guard
      let localState,
      let json = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
      let profile = json["profile"] as? [String: Any],
      let name = profile["last_used"] as? String,
      !name.isEmpty
    else { return "Default" }
    return name
  }
}
