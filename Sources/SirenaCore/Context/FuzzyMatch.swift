import Foundation

/// Small fuzzy-matching helpers for app names, tab titles and accessibility labels.
public enum Fuzzy {
    public static func normalize(_ s: String) -> String { WakeWord.normalize(s) }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// 0...1 similarity between two normalized strings.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 0 }
        return 1 - Double(levenshtein(a, b)) / Double(maxLen)
    }

    /// Score how well `query` names `candidate` (both raw). 1 = exact.
    public static func score(query: String, candidate: String) -> Double {
        let q = normalize(query), c = normalize(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        if q == c { return 1 }
        if c.hasPrefix(q + " ") || c.hasPrefix(q) && Double(q.count) / Double(c.count) > 0.5 { return 0.92 }
        let qTokens = Set(q.split(separator: " ").map(String.init))
        let cTokens = c.split(separator: " ").map(String.init)
        if qTokens.count == 1, cTokens.contains(q) { return 0.88 }
        if c.contains(q) { return 0.8 }
        // token overlap with fuzzy token equality
        var matched = 0
        for qt in qTokens {
            if cTokens.contains(where: { $0 == qt || ($0.count > 3 && similarity($0, qt) >= 0.8) || ($0.hasPrefix(qt) && qt.count >= 3) }) { matched += 1 }
        }
        let overlap = Double(matched) / Double(qTokens.count)
        let sim = similarity(q, c)
        return max(overlap * 0.85, sim)
    }

    /// Best candidate above `threshold`.
    public static func best<T>(_ query: String, in items: [T], name: (T) -> String, threshold: Double = 0.6) -> (item: T, score: Double)? {
        var bestItem: T?
        var bestScore = 0.0
        for item in items {
            let s = score(query: query, candidate: name(item))
            if s > bestScore { bestScore = s; bestItem = item }
        }
        if let b = bestItem, bestScore >= threshold { return (b, bestScore) }
        return nil
    }
}
