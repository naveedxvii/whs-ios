import Foundation

/// Saves and loads the backup in the private app folder of the signed-in Google account.
enum DriveSync {
    static let fileName = "wani-data.json"

    struct FileList: Decodable {
        let files: [FileEntry]
    }

    struct FileEntry: Decodable {
        let id: String
        let modifiedTime: String
    }

    struct Remote {
        let id: String
        let modified: Date
    }

    static func upload(_ data: Data) async throws -> Date {
        let token = try await GoogleAuth.shared.validAccessToken()

        if let existing = try await findFile(token: token) {
            var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(existing.id)?uploadType=media&fields=modifiedTime")!)
            req.httpMethod = "PATCH"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            let (out, response) = try await URLSession.shared.data(for: req)
            try check(response)
            return modifiedDate(from: out)
        }

        let boundary = "wani-\(UUID().uuidString)"
        let meta = "{\"name\":\"\(fileName)\",\"parents\":[\"appDataFolder\"]}"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(meta)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=modifiedTime")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (out, response) = try await URLSession.shared.data(for: req)
        try check(response)
        return modifiedDate(from: out)
    }

    /// The time Drive last saved the backup, or nil if there is none yet.
    static func remoteModified() async throws -> Date? {
        let token = try await GoogleAuth.shared.validAccessToken()
        return try await findFile(token: token)?.modified
    }

    static func download() async throws -> (Data, Date) {
        let token = try await GoogleAuth.shared.validAccessToken()
        guard let remote = try await findFile(token: token) else {
            throw GoogleError.noBackup
        }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(remote.id)?alt=media")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response)
        return (data, remote.modified)
    }

    private static func findFile(token: String) async throws -> Remote? {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "name = '\(fileName)'"),
            URLQueryItem(name: "fields", value: "files(id,modifiedTime)"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response)
        let list = try JSONDecoder().decode(FileList.self, from: data)
        guard let file = list.files.first else { return nil }
        return Remote(id: file.id, modified: parseDate(file.modifiedTime))
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw GoogleError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw GoogleError.driveFailed(http.statusCode) }
    }

    private static func modifiedDate(from data: Data) -> Date {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["modifiedTime"] as? String else { return Date() }
        return parseDate(text)
    }

    private static func parseDate(_ text: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? Date.distantPast
    }
}
