import Foundation

/// A forgiving HTML tokenizer. Real pages are rarely well-formed XML, so instead of a parser
/// that gives up on the first stray `<`, this walks the text once and reports start tags (with
/// decoded attributes), end tags and text. Comments, doctypes and processing instructions are
/// dropped; script/style-like elements are returned as a single raw text token.
struct HTMLTag: Sendable {
    /// Lowercased.
    var name: String
    /// Lowercased names, entity-decoded values.
    var attributes: [String: String]
    var selfClosing: Bool

    func has(class token: String) -> Bool {
        (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).contains { $0 == token }
    }
}

enum HTMLToken: Sendable {
    case start(HTMLTag)
    case end(String)
    case text(String)
}

enum HTMLTokenizer {
    /// Elements whose content is not markup.
    static let rawText: Set<String> = ["script", "style", "xmp", "iframe", "noembed", "noframes", "noscript", "textarea", "title"]
    /// Of those, the ones whose content still has entities (RCDATA).
    static let escapableRawText: Set<String> = ["textarea", "title"]
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr", "param", "keygen"]

    static func tokenize(_ html: String, _ visit: (HTMLToken) -> Void) {
        let s = Array(html.unicodeScalars)
        let n = s.count
        var i = 0
        var text = String.UnicodeScalarView()

        func flushText() {
            guard !text.isEmpty else { return }
            visit(.text(HTMLEntities.decode(String(text))))
            text = String.UnicodeScalarView()
        }
        func isAlpha(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
        func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" }
        func lower(_ c: Unicode.Scalar) -> Unicode.Scalar { (c >= "A" && c <= "Z") ? Unicode.Scalar(c.value + 32) ?? c : c }
        func indexOf(_ pattern: String, from: Int) -> Int? {
            let p = Array(pattern.unicodeScalars)
            guard !p.isEmpty, from <= n - p.count else { return nil }
            var k = from
            while k <= n - p.count {
                if s[k] == p[0] {
                    var j = 1
                    while j < p.count && s[k + j] == p[j] { j += 1 }
                    if j == p.count { return k }
                }
                k += 1
            }
            return nil
        }
        /// Case-insensitive search for "</name" followed by a delimiter.
        func closing(_ name: String, from: Int) -> Int? {
            let p = Array(name.unicodeScalars)
            var k = from
            while k + 1 + p.count < n {
                if s[k] == "<" && s[k + 1] == "/" {
                    var j = 0
                    while j < p.count && lower(s[k + 2 + j]) == p[j] { j += 1 }
                    if j == p.count {
                        let after = k + 2 + p.count
                        if after >= n || isSpace(s[after]) || s[after] == ">" || s[after] == "/" { return k }
                    }
                }
                k += 1
            }
            return nil
        }
        func startsWith(_ pattern: String, at: Int) -> Bool {
            let p = Array(pattern.unicodeScalars)
            guard at >= 0, at + p.count <= n else { return false }
            for j in 0..<p.count where s[at + j] != p[j] { return false }
            return true
        }
        func skipPast(_ ch: Unicode.Scalar, from: Int) -> Int {
            var k = from
            while k < n && s[k] != ch { k += 1 }
            return min(k + 1, n)
        }

        while i < n {
            let c = s[i]
            guard c == "<", i + 1 < n else { text.append(c); i += 1; continue }
            let next = s[i + 1]
            if next == "!" {
                flushText()
                if i + 3 < n && s[i + 2] == "-" && s[i + 3] == "-" {
                    i = indexOf("-->", from: i + 4).map { $0 + 3 } ?? n
                } else if startsWith("[CDATA[", at: i + 2), let cdataEnd = indexOf("]]>", from: i + 9) {
                    visit(.text(String(String.UnicodeScalarView(s[(i + 9)..<cdataEnd]))))
                    i = cdataEnd + 3
                } else {
                    i = skipPast(">", from: i + 2)
                }
                continue
            }
            if next == "?" { flushText(); i = skipPast(">", from: i + 2); continue }
            if next == "/" {
                var k = i + 2
                var name = String.UnicodeScalarView()
                while k < n && !isSpace(s[k]) && s[k] != ">" && s[k] != "/" { name.append(lower(s[k])); k += 1 }
                guard !name.isEmpty, let f = name.first, isAlpha(f) else {
                    if name.isEmpty && k < n && s[k] == ">" { i = k + 1; continue } // "</>" is ignored
                    text.append(c); i += 1; continue
                }
                flushText()
                i = skipPast(">", from: k)
                visit(.end(String(name)))
                continue
            }
            guard isAlpha(next) else { text.append(c); i += 1; continue }

            // Start tag.
            flushText()
            var k = i + 1
            var name = String.UnicodeScalarView()
            while k < n && !isSpace(s[k]) && s[k] != ">" && s[k] != "/" { name.append(lower(s[k])); k += 1 }
            var attrs: [String: String] = [:]
            var selfClosing = false
            while k < n {
                while k < n && isSpace(s[k]) { k += 1 }
                guard k < n else { break }
                if s[k] == ">" { k += 1; break }
                if s[k] == "/" {
                    k += 1
                    if k < n && s[k] == ">" { selfClosing = true; k += 1; break }
                    continue
                }
                let attrStart = k
                var an = String.UnicodeScalarView()
                while k < n && !isSpace(s[k]) && s[k] != "=" && s[k] != ">" && s[k] != "/" { an.append(lower(s[k])); k += 1 }
                while k < n && isSpace(s[k]) { k += 1 }
                var value = ""
                if k < n && s[k] == "=" {
                    k += 1
                    while k < n && isSpace(s[k]) { k += 1 }
                    if k < n && (s[k] == "\"" || s[k] == "'") {
                        let q = s[k]
                        let start = k + 1
                        k = start
                        while k < n && s[k] != q { k += 1 }
                        value = String(String.UnicodeScalarView(s[start..<min(k, n)]))
                        k = min(k + 1, n)
                    } else {
                        var v = String.UnicodeScalarView()
                        while k < n && !isSpace(s[k]) && s[k] != ">" { v.append(s[k]); k += 1 }
                        value = String(v)
                    }
                }
                // A nameless attribute (`<a ="x">`) is dropped; never stall on a character.
                if an.isEmpty { if k == attrStart { k += 1 }; continue }
                let key = String(an)
                if attrs[key] == nil { attrs[key] = HTMLEntities.decode(value) }
            }
            let tagName = String(name)
            visit(.start(HTMLTag(name: tagName, attributes: attrs, selfClosing: selfClosing)))
            i = k
            if rawText.contains(tagName) && !selfClosing {
                let end = closing(tagName, from: i) ?? n
                if end > i {
                    let raw = String(String.UnicodeScalarView(s[i..<end]))
                    visit(.text(escapableRawText.contains(tagName) ? HTMLEntities.decode(raw) : raw))
                }
                visit(.end(tagName))
                i = end < n ? skipPast(">", from: end + 2) : n
            }
        }
        flushText()
    }
}

/// HTML character references: numeric ones and the named entities that actually occur in
/// pages (the full HTML5 table is ~2,000 names; the rest are left as written).
enum HTMLEntities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "", "rlm": "", "shy": "",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "minus": "−",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»",
        "lsaquo": "‹", "rsaquo": "›", "bull": "•", "middot": "·", "prime": "′", "Prime": "″", "dagger": "†", "Dagger": "‡",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤", "sect": "§", "para": "¶", "deg": "°",
        "plusmn": "±", "times": "×", "divide": "÷", "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³",
        "micro": "µ", "iexcl": "¡", "iquest": "¿", "ordf": "ª", "ordm": "º", "not": "¬", "macr": "¯", "acute": "´", "cedil": "¸", "uml": "¨",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "rArr": "⇒", "lArr": "⇐", "hArr": "⇔",
        "le": "≤", "ge": "≥", "ne": "≠", "asymp": "≈", "equiv": "≡", "infin": "∞", "sum": "∑", "prod": "∏", "radic": "√",
        "check": "✓", "star": "☆", "hearts": "♥", "spades": "♠", "clubs": "♣", "diams": "♦", "loz": "◊",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ", "omega": "ω",
        "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Sigma": "Σ", "Omega": "Ω",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç",
        "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï",
        "ETH": "Ð", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø",
        "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý", "THORN": "Þ", "szlig": "ß",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç",
        "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï",
        "eth": "ð", "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø",
        "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "thorn": "þ", "yuml": "ÿ",
        "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜",
    ]
    /// Legacy entities browsers accept without the trailing semicolon.
    static let semicolonOptional: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]
    /// Numeric references in 0x80–0x9F mean Windows-1252 characters, as browsers interpret them.
    static let cp1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030,
        0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022,
        0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            guard u[i] == "&" else { out.append(u[i]); i += 1; continue }
            var j = i + 1
            if j < u.count && u[j] == "#" {
                j += 1
                var hex = false
                if j < u.count && (u[j] == "x" || u[j] == "X") { hex = true; j += 1 }
                let start = j
                var value: UInt32 = 0
                var overflow = false
                while j < u.count, j - start < 8 {
                    let c = u[j]
                    let d: UInt32?
                    if c >= "0" && c <= "9" { d = c.value - 48 } else if hex && c >= "a" && c <= "f" { d = c.value - 87 } else if hex && c >= "A" && c <= "F" { d = c.value - 55 } else { d = nil }
                    guard let d else { break }
                    value = value &* (hex ? 16 : 10) &+ d
                    if value > 0x10FFFF { overflow = true }
                    j += 1
                }
                guard j > start else { out.append(u[i]); i += 1; continue }
                if j < u.count && u[j] == ";" { j += 1 }
                if let mapped = cp1252[value] { value = mapped }
                let scalar = (overflow || value == 0) ? nil : Unicode.Scalar(value)
                out.append(scalar ?? "\u{FFFD}")
                i = j
                continue
            }
            let start = j
            while j < u.count, j - start < 10, (u[j] >= "a" && u[j] <= "z") || (u[j] >= "A" && u[j] <= "Z") || (u[j] >= "0" && u[j] <= "9") { j += 1 }
            let name = String(String.UnicodeScalarView(u[start..<j]))
            if j < u.count, u[j] == ";", let rep = named[name] {
                out.append(contentsOf: rep.unicodeScalars)
                i = j + 1
            } else if semicolonOptional.contains(name), let rep = named[name] {
                out.append(contentsOf: rep.unicodeScalars)
                i = j
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return String(out)
    }
}
