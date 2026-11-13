import UIKit
import Foundation

/// Splits all of the app's data into QR frames. Each frame reads: WS|index|total|Z-or-R|part
/// Z means the data is zlib-compressed before being split into parts (R means raw).
enum QRFrames {
    static let partSize = 600

    static func makeTexts(_ raw: Data) -> [String] {
        var payload = raw
        var flag = "R"
        if let compressed = try? ((raw as NSData).compressed(using: .zlib) as Data),
           compressed.count < raw.count {
            payload = compressed
            flag = "Z"
        }
        let chars = Array(payload.base64EncodedString())
        let parts = stride(from: 0, to: chars.count, by: partSize).map {
            String(chars[$0..<min($0 + partSize, chars.count)])
        }
        let total = parts.count
        return parts.enumerated().map { "WS|\($0.offset + 1)|\(total)|\(flag)|\($0.element)" }
    }

    static func makeImages(_ raw: Data) -> [UIImage] {
        makeTexts(raw).compactMap { qrImage($0) }
    }
}

enum FrameResult {
    case ignored
    case progress(Int, Int)
    case complete(Data)
}

/// Collects frames from the scanner until every part has arrived.
struct QRAssembler {
    private var total = 0
    private var compressed = false
    private var parts: [Int: String] = [:]
    private var done = false

    mutating func add(_ text: String) -> FrameResult {
        guard !done else { return .ignored }
        let p = text.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
        guard p.count == 5, p[0] == "WS",
              let index = Int(p[1]), let count = Int(p[2]),
              count > 0, index >= 1, index <= count else {
            return .ignored
        }
        if total != count {
            total = count
            compressed = p[3] == "Z"
            parts = [:]
        }
        parts[index] = String(p[4])
        if parts.count < count {
            return .progress(parts.count, count)
        }
        let joined = (1...count).map { parts[$0] ?? "" }.joined()
        guard let raw = Data(base64Encoded: joined) else {
            reset()
            return .ignored
        }
        var decoded: Data? = raw
        if compressed {
            decoded = try? ((raw as NSData).decompressed(using: .zlib) as Data)
        }
        guard let data = decoded else {
            reset()
            return .ignored
        }
        done = true
        return .complete(data)
    }

    private mutating func reset() {
        parts = [:]
        total = 0
    }
}
