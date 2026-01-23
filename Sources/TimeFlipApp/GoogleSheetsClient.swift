import Foundation

struct GoogleSheetInfo: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
}

@MainActor
protocol GoogleSheetsClient {
    func fetchSheets(accessToken: String, spreadsheetId: String) async throws -> [GoogleSheetInfo]
    func appendRow(accessToken: String, spreadsheetId: String, range: String, values: [[String]]) async throws
}

@MainActor
final class GoogleSheetsAPIClient: GoogleSheetsClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchSheets(accessToken: String, spreadsheetId: String) async throws -> [GoogleSheetInfo] {
        let encodedId = spreadsheetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? spreadsheetId
        guard let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(encodedId)?fields=sheets(properties(sheetId,title))") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try GoogleAPIError.validate(response: response, data: data)
        let payload = try JSONDecoder().decode(SheetsMetadataResponse.self, from: data)
        return payload.sheets.map { GoogleSheetInfo(id: $0.properties.sheetId, title: $0.properties.title) }
    }

    func appendRow(accessToken: String, spreadsheetId: String, range: String, values: [[String]]) async throws {
        let encodedId = spreadsheetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? spreadsheetId
        let encodedRange = range.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? range
        guard let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(encodedId)/values/\(encodedRange):append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = SheetsAppendRequest(values: values)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        try GoogleAPIError.validate(response: response, data: data)
    }
}

private struct SheetsMetadataResponse: Decodable {
    let sheets: [SheetEntry]
}

private struct SheetEntry: Decodable {
    let properties: SheetProperties
}

private struct SheetProperties: Decodable {
    let sheetId: Int
    let title: String
}

private struct SheetsAppendRequest: Encodable {
    let values: [[String]]
}
