import Foundation

/// Canonical JSON + FNV-1a, the Swift half of the content-hash contract.
///
/// This must agree with `canonicalJson()` and `fnv1a64()` in
/// `src/lib/tripPackage.js` byte for byte. The golden fixtures are the proof:
/// if these two implementations ever disagree, `TripCoreTests` fails on a file
/// the JS suite is simultaneously asserting against.
///
/// Three rules exist purely because the two languages disagree by default:
///
/// 1. **Keys are sorted by UTF-16 code unit**, matching JS `Array.sort()`.
///    Swift's native `String` comparison uses Unicode canonical ordering, which
///    differs for non-ASCII keys. Today every key is ASCII, so both agree — the
///    explicit sort keeps that true if a key ever isn't.
/// 2. **Null members are dropped from objects**, so an absent field and an
///    explicitly-null one hash identically. Elevation is null on routes without
///    it, and a planner that stops emitting the key must not change the hash.
/// 3. **Non-integers print at exactly 6 decimals.** Neither language's default
///    "shortest representation that round-trips" is specified compatibly.
///
/// Rule 3 has a safety margin worth knowing about: the builder rounds
/// coordinates to 5 decimals and elevation coverage to 3, so the 6th decimal is
/// always zero and the two languages never have to agree on how to break a
/// rounding tie (JS `toFixed` rounds half away from zero, C `printf` rounds half
/// to even). Keep hash precision strictly greater than data precision.
public enum CanonicalJSON {
    /// Decimals used for any non-integral number. Must exceed the precision of
    /// every value the builder emits — see the note above.
    static let fractionDigits = 6

    /// Canonicalise the JSON in `data`, optionally omitting top-level keys.
    ///
    /// Works on the parsed JSON graph rather than on a decoded model on purpose:
    /// the hash describes the *file*, so a field this build doesn't know about
    /// still contributes. That keeps a newer planner's additions verifiable by
    /// an older app instead of failing the hash.
    public static func canonicalize(data: Data, omittingTopLevelKeys omit: Set<String> = []) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if !omit.isEmpty, let dictionary = object as? [String: Any] {
            return canonicalize(value: dictionary.filter { !omit.contains($0.key) })
        }
        return canonicalize(value: object)
    }

    public static func canonicalize(value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"

        case let number as NSNumber:
            // JSONSerialization funnels booleans through NSNumber too, and
            // `true` must not serialise as `1`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return canonicalNumber(number.doubleValue)

        case let string as String:
            return escape(string)

        case let array as [Any]:
            return "[" + array.map { canonicalize(value: $0) }.joined(separator: ",") + "]"

        case let dictionary as [String: Any]:
            let members = dictionary
                .filter { !($0.value is NSNull) }
                .sorted { lessThanByUTF16($0.key, $1.key) }
                .map { "\(escape($0.key)):\(canonicalize(value: $0.value))" }
            return "{" + members.joined(separator: ",") + "}"

        default:
            return "null"
        }
    }

    /// Mirrors JS `Number.isInteger(n) ? String(n) : n.toFixed(6)`.
    static func canonicalNumber(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(format: "%.\(fractionDigits)f", value)
    }

    /// Mirrors `JSON.stringify` for strings: escape `"`, `\` and the control
    /// range; leave everything else as raw UTF-8 (JS does not escape non-ASCII).
    static func escape(_ string: String) -> String {
        var out = "\""
        out.reserveCapacity(string.utf8.count + 2)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// JS sorts strings by UTF-16 code unit; Swift's `<` does not.
    static func lessThanByUTF16(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs.utf16.makeIterator()
        var right = rhs.utf16.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let l?, let r?):
                if l != r { return l < r }
            }
        }
    }
}

/// 64-bit FNV-1a over UTF-8 bytes, as 16 lowercase hex digits.
///
/// Chosen over SHA-256 so the JS side stays synchronous (no WebCrypto promise
/// inside an export handler). This detects change and truncation, and is not a
/// security hash — the algorithm name travels in the payload so it can be
/// replaced without ambiguity.
public enum FNV1a {
    public static func hash64(_ text: String) -> String {
        let prime: UInt64 = 0x100_0000_01b3
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        return String(format: "%016lx", hash)
    }
}
