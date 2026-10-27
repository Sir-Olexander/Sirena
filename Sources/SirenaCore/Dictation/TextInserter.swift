import Foundation
import AppKit

/// Puts text into whatever has the keyboard focus: clipboard → ⌘V → restore the clipboard.
public final class TextInserter {
    public static let shared = TextInserter()
    /// Length of the last inserted chunk, so "delete that" can remove it.
    public private(set) var lastInsertedLength = 0
    public private(set) var lastInsertedText = ""
    private let pasteboard = NSPasteboard.general

    public init() {}

    private func saveClipboard() -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var any = false
            for type in item.types {
                if let d = item.data(forType: type) { copy.setData(d, forType: type); any = true }
            }
            return any ? copy : nil
        }
    }

    private func restoreClipboard(_ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Inserts `text` at the cursor through the clipboard. Returns when the paste has been sent.
    public func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let saved = saveClipboard()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        usleep(30_000)
        Keyboard.press(KeyCombo("v", [.command]))
        lastInsertedLength = text.count
        lastInsertedText = text
        // Give the target app time to read the pasteboard before restoring it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { [self] in
            // Only restore if nobody else changed the clipboard in the meantime.
            if pasteboard.string(forType: .string) == text { restoreClipboard(saved) }
        }
    }

    /// Types with keyboard events instead of the clipboard (for short strings or when paste is unwelcome).
    public func type(_ text: String) {
        Keyboard.typeUnicode(text)
        lastInsertedLength = text.count
        lastInsertedText = text
    }

    /// Removes the last inserted chunk (selection through the Accessibility API, else backspaces).
    public func deleteLastInserted() {
        let n = lastInsertedLength
        guard n > 0 else { return }
        if let el = AX.focusedTextElement(), let value = el.valueString, value.hasSuffix(lastInsertedText),
           let rangeValue = el.attribute(kAXSelectedTextRangeAttribute), CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                let start = max(0, range.location + range.length - n)
                var newRange = CFRange(location: start, length: n)
                if let v = AXValueCreate(.cfRange, &newRange), el.set(kAXSelectedTextRangeAttribute, v) {
                    Keyboard.press(KeyCombo("delete"))
                    lastInsertedLength = 0; lastInsertedText = ""
                    return
                }
            }
        }
        for _ in 0..<min(n, 400) { Keyboard.press(KeyCombo("delete")) }
        lastInsertedLength = 0
        lastInsertedText = ""
    }

    public func forget() { lastInsertedLength = 0; lastInsertedText = "" }
}
