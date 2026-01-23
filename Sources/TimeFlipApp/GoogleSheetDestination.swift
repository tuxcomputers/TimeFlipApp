import Foundation

struct GoogleSheetDestination: Equatable, Sendable {
    let spreadsheetId: String
    let sheetGid: Int?

    static func parse(from urlString: String) -> GoogleSheetDestination? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed) else { return nil }
        let pathParts = url.pathComponents
        guard let idIndex = pathParts.firstIndex(of: "d"), pathParts.count > idIndex + 1 else {
            return nil
        }
        let spreadsheetId = pathParts[idIndex + 1]
        guard !spreadsheetId.isEmpty else { return nil }

        let gid = parseGid(from: url)
        return GoogleSheetDestination(spreadsheetId: spreadsheetId, sheetGid: gid)
    }

    private static func parseGid(from url: URL) -> Int? {
        if let fragment = url.fragment {
            if let gid = parseGid(from: fragment) {
                return gid
            }
        }
        if let query = url.query {
            if let gid = parseGid(from: query) {
                return gid
            }
        }
        return nil
    }

    private static func parseGid(from string: String) -> Int? {
        let parts = string.split(separator: "&")
        for part in parts {
            let pair = part.split(separator: "=")
            guard pair.count == 2 else { continue }
            if pair[0] == "gid", let gid = Int(pair[1]) {
                return gid
            }
        }
        return nil
    }
}
