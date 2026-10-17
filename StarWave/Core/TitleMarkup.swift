import Foundation

/// Windows McText grammar. k/m/n/o are accepted and hidden, not rendered as
/// unsupported Minecraft effects. Short colors/reset clear bold; hex keeps it.
enum TitleMarkup {
    struct Segment: Equatable {
        let text: String
        let hex: String?
        let bold: Bool
    }

    private static let token = try! NSRegularExpression(pattern: #"&#([0-9a-f]{6})|&([0-9a-fk-or])"#, options: .caseInsensitive)
    private static let palette = ["0":"000000", "1":"0000AA", "2":"00AA00", "3":"00AAAA", "4":"AA0000", "5":"AA00AA", "6":"FFAA00", "7":"AAAAAA", "8":"555555", "9":"5555FF", "a":"55FF55", "b":"55FFFF", "c":"FF5555", "d":"FF55FF", "e":"FFFF55", "f":"FFFFFF"]

    static func segments(in value: String) -> [Segment] {
        var result: [Segment] = [], hex: String?, bold = false
        var cursor = value.startIndex
        for match in token.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let range = Range(match.range, in: value) else { continue }
            if cursor < range.lowerBound { result.append(Segment(text: String(value[cursor..<range.lowerBound]), hex: hex, bold: bold)) }
            if let color = Range(match.range(at: 1), in: value) { hex = String(value[color]).uppercased() }
            else if let codeRange = Range(match.range(at: 2), in: value) {
                let code = String(value[codeRange]).lowercased()
                if let color = palette[code] { hex = color; bold = false }
                else if code == "l" { bold = true }
                else if code == "r" { hex = nil; bold = false }
            }
            cursor = range.upperBound
        }
        if cursor < value.endIndex { result.append(Segment(text: String(value[cursor...]), hex: hex, bold: bold)) }
        return result
    }

    static func plainText(_ value: String) -> String { segments(in: value).map(\.text).joined() }
    static func visibleLength(_ value: String) -> Int { plainText(value).utf16.count }
}
