import Foundation

public enum BrowserHTTPRequest {
    public enum Failure: Error { case refused }
    // nil means the bounded request is incomplete. Other failures must close the connection.
    public static func parse(_ data: Data, token: String) throws -> UrlOpenRequest? {
        guard data.count <= 6144 else { throw Failure.refused }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 4096 { throw Failure.refused }; return nil
        }
        guard end.upperBound <= 4096, let text = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw Failure.refused }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first == "POST /\(token) HTTP/1.1" || first == "POST /\(token) HTTP/1.0" else { throw Failure.refused }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.refused }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw Failure.refused }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["origin"] == nil, headers["transfer-encoding"] == nil,
              let raw = headers["content-length"], !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let size = Int(raw), size > 0, size <= UrlOpenRequest.maxBytes else { throw Failure.refused }
        let expected = end.upperBound + size
        if data.count < expected { return nil }
        guard data.count == expected, let body = String(data: data[end.upperBound...], encoding: .utf8),
              !body.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let request = UrlOpenRequest.classify(body) else { throw Failure.refused }
        return request
    }
}
