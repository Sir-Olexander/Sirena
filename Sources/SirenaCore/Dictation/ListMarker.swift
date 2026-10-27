import Foundation

/// A spoken list marker at the start of a dictated chunk: "first point, …", "point two …", "next item …",
/// "secondly …", "ponto três …". The marker is removed; the item is inserted on its own line, numbered.
public struct ListMarker: Equatable {
    /// Explicit number, or nil for "next".
    public var number: Int?
    /// The item text after the marker (may be empty: "second point," then the item in the next pause).
    public var rest: String

    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5, "6th": 6, "7th": 7, "8th": 8, "9th": 9, "10th": 10,
        "firstly": 1, "secondly": 2, "thirdly": 3, "fourthly": 4, "fifthly": 5,
        "primeiro": 1, "segundo": 2, "terceiro": 3, "quarto": 4, "quinto": 5, "sexto": 6, "sétimo": 7, "setimo": 7, "oitavo": 8, "nono": 9, "décimo": 10, "decimo": 10,
        "primeira": 1, "segunda": 2, "terceira": 3, "quarta": 4, "quinta": 5,
    ]
    static let cardinals: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "um": 1, "uma": 1, "dois": 2, "duas": 2, "três": 3, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6, "sete": 7, "oito": 8, "nove": 9, "dez": 10,
    ]
    static let nouns = "(?:point|item|thing|step|bullet|idea|issue|task|question|reason|option|topic|note|ponto|item|passo|t[óo]pico|quest[ãa]o|tarefa|ideia)"
    static let tail = "\\b[\\s,.:;\\-–—]*(.*)$"

    public static func parse(_ raw: String, listActive: Bool) -> ListMarker? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = "^\\s*(?:(?:and|e|so|then|ok|okay|now|um|uh)[,\\s]+)?(?:(?:the|o|a)\\s+)?"
        func num(_ w: String) -> Int? {
            let t = w.lowercased()
            return ordinals[t] ?? cardinals[t] ?? Int(t)
        }
        // "first point …", "segundo ponto …"
        if let m = text.firstMatch(lead + "(\\S+)\\s+" + nouns + tail), let n = ordinals[m[1].lowercased()] {
            return ListMarker(number: n, rest: m[2])
        }
        // "point one …", "item 3 …", "ponto dois …", "number two …"
        if let m = text.firstMatch(lead + "(?:" + nouns + "|number|n[úu]mero)\\s+(?:number\\s+|n[úu]mero\\s+)?(\\S+?)" + tail), let n = num(m[1].trimmingCharacters(in: .punctuationCharacters)) {
            return ListMarker(number: n, rest: m[2])
        }
        // "next point …", "another item …", "próximo ponto …"
        if let m = text.firstMatch(lead + "(?:next|another|pr[óo]ximo|pr[óo]xima|outro|outra)\\s+" + nouns + tail) {
            return ListMarker(number: nil, rest: m[1])
        }
        // "firstly …", "secondly …"
        if let m = text.firstMatch("^\\s*(firstly|secondly|thirdly|fourthly|fifthly)" + tail) {
            return ListMarker(number: ordinals[m[1].lowercased()], rest: m[2])
        }
        if listActive {
            // "finally, …", "lastly …" inside a list
            if let m = text.firstMatch("^\\s*(?:and\\s+)?(?:lastly|finally|por fim|por [úu]ltimo)" + "[\\s,.:;\\-–—]+(.*)$") {
                return ListMarker(number: nil, rest: m[1])
            }
            // bare ordinal followed by a comma: "second, …", "terceiro: …"
            if let m = text.firstMatch("^\\s*(\\S+?)[,:]\\s*(.*)$"), let n = ordinals[m[1].lowercased()] {
                return ListMarker(number: n, rest: m[2])
            }
        }
        return nil
    }

    /// Number of the last numbered line ("3. …") in existing text, so a new dictation session continues the list.
    public static func lastNumber(in text: String) -> Int? {
        guard let lastLine = text.components(separatedBy: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let m = lastLine.firstMatch("^\\s*(\\d{1,3})[.)]\\s") else { return nil }
        return Int(m[1])
    }
}
