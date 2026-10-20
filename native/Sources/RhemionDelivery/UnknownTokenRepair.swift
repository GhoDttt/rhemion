// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Repairs Parakeet's `<unk>` marker. The model's vocabulary has no quote marks, no dash and no Cyrillic yo
/// (U+0451), so where
/// the speech calls for one of them it emits `<unk>`. Only high-confidence patterns are restored; anything
/// ambiguous is removed rather than given an invented meaning:
///   1. inside a Cyrillic word, when the word spelled with yo is a known Russian word → yo;
///   2. a pair around a short phrase → quotes, «…» for Cyrillic text, “…” otherwise;
///   3. alone between two spaces → an em dash;
///   4. anything else → removed.
public enum UnknownTokenRepair {
    public static let token = "<unk>"
    /// Longest phrase (in words) a pair of markers may enclose to count as a quotation.
    static let maxQuotedWords = 12

    /// Russian words spelled with yo, which Parakeet cannot write. Lowercase.
    static let yoWords: Set<String> = [
        "чё", "всё", "её", "ещё", "моё", "твоё", "своё", "неё", "нём", "чём", "причём", "почём",
        "приём", "объём", "подъём", "идём", "пойдём", "придём", "найдём", "живём", "даём", "берём",
        "ждём", "зовём", "ведём", "несём", "везём", "поём", "пьём", "льём", "бьём", "шьём", "встаём",
        "даёт", "встаёт", "идёт", "пойдёт", "придёт", "найдёт", "живёт", "берёт", "ждёт", "зовёт",
        "ведёт", "несёт", "везёт", "растёт", "всё-таки", "твёрдо", "лёгкий", "тёплый",
    ]

    public static func repair(_ text: String) -> String {
        guard text.contains(token) else { return text }
        var parts = text.components(separatedBy: token)
        let markers = parts.count - 1
        // What each marker becomes; nil = undecided.
        var out = [String?](repeating: nil, count: markers)

        func isLetter(_ c: Character?) -> Bool { c?.isLetter ?? false }
        func isCyrillic(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) } }

        // 1. Yo inside a known Cyrillic word.
        for k in 0..<markers {
            let left = parts[k], right = parts[k + 1]
            guard let last = left.last, last.isLetter, isCyrillic(last) else { continue }
            let leftWord = String(left.reversed().prefix { $0.isLetter || $0 == "-" }.reversed())
            let rightWord = String(right.prefix { $0.isLetter || $0 == "-" })
            if yoWords.contains((leftWord + "ё" + rightWord).lowercased()) {
                out[k] = last.isUppercase && leftWord.count == 1 && rightWord.allSatisfy(\.isUppercase) ? "Ё" : "ё"
            }
        }

        // 2. Quote pairs: an opening marker (start or space before, a letter or digit after) followed by the next
        //    undecided marker as a closing one (a non-space before, end, space or punctuation after).
        func opening(_ k: Int) -> Bool {
            let before = parts[k].last, after = parts[k + 1].first
            return (before == nil || before!.isWhitespace || before == "(") && (after.map { $0.isLetter || $0.isNumber } ?? false)
        }
        func closing(_ k: Int) -> Bool {
            let before = parts[k].last, after = parts[k + 1].first
            return before.map { !$0.isWhitespace } ?? false && (after == nil || after!.isWhitespace || after!.isPunctuation)
        }
        var k = 0
        while k < markers {
            guard out[k] == nil, opening(k) else { k += 1; continue }
            guard let j = ((k + 1)..<markers).first(where: { out[$0] == nil }), closing(j) else { k += 1; continue }
            let inner = parts[(k + 1)...j].joined(separator: " ")
            let words = inner.split(whereSeparator: \.isWhitespace).count
            guard words <= maxQuotedWords, !inner.contains(where: { ".!?".contains($0) }) else { k += 1; continue }
            let cyrillic = inner.contains { $0.isLetter && isCyrillic($0) }
            out[k] = cyrillic ? "«" : "“"
            out[j] = cyrillic ? "»" : "”"
            k = j + 1
        }

        // 3. Alone between spaces: a dash. 4. Anything else: removed.
        for k in 0..<markers where out[k] == nil {
            let spaced = (parts[k].last?.isWhitespace ?? false) && (parts[k + 1].first?.isWhitespace ?? false)
            out[k] = spaced ? "—" : ""
        }

        var result = parts.removeFirst()
        for (k, part) in parts.enumerated() { result += (out[k] ?? "") + part }
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        for p in [",", ".", "!", "?", ":", ";"] { result = result.replacingOccurrences(of: " " + p, with: p) }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
