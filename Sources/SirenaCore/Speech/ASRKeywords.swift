import Foundation

/// Vocabulary hints sent to Muse Voice Transcribe. The service rejects the whole session when a hint is
/// longer than 30 characters ("ASR keyword N exceeds the maximum length of 30 characters"), so every list
/// goes through `sanitize` first.
public enum ASRKeywords {
    public static let maxLength = 30
    public static let maxCount = 100
    /// Used when the service rejected the hints: listening must work regardless.
    public static let minimal = ["Sirena", "Hey Sirena"]

    public static func sanitize(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in keywords {
            var k = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if k.count > maxLength {
                // Cut at a word boundary, else hard cut.
                let cut = String(k.prefix(maxLength))
                let next = k[k.index(k.startIndex, offsetBy: maxLength)]
                if next == " " { k = cut }   // the word ends exactly at the limit
                else if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= 3 { k = String(cut[..<space]) }
                else { k = cut }
                k = k.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
            guard k.count >= 2, k.count <= maxLength, seen.insert(k.lowercased()).inserted else { continue }
            out.append(k)
            if out.count == maxCount { break }
        }
        return out
    }
}
