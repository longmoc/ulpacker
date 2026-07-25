import Foundation

/// Date handling shared by everything that reads or writes a package.
///
/// Foundation's built-in `.iso8601` strategy does not carry fractional seconds,
/// which breaks in both directions:
///
/// * **Writing** — a round trip silently truncates, so a decoded package no
///   longer equals the one that was encoded.
/// * **Reading** — JavaScript's `toISOString()` *always* emits milliseconds, so
///   anything the web planner writes (`2026-07-25T07:46:27.472Z`) fails to parse
///   with the default strategy.
///
/// So: always emit fractional seconds, and accept timestamps with or without
/// them. Being liberal on input matters because the other end of this contract
/// is a different language with different defaults.
public enum ISO8601 {
    /// Shared formatters behind a lock.
    ///
    /// `ISO8601DateFormatter` is not `Sendable`, and this code is called from
    /// the Core Location callback while the app is in the background — so the
    /// compiler's objection is a real one, not a formality. Reusing two locked
    /// instances beats allocating a formatter per call: reading back a long
    /// recording parses thousands of timestamps in one pass.
    private final class Formatters: @unchecked Sendable {
        static let shared = Formatters()

        private let lock = NSLock()
        private let withFractional: ISO8601DateFormatter
        private let withoutFractional: ISO8601DateFormatter

        init() {
            withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            withoutFractional = ISO8601DateFormatter()
            withoutFractional.formatOptions = [.withInternetDateTime]
        }

        func string(from date: Date) -> String {
            lock.lock()
            defer { lock.unlock() }
            return withFractional.string(from: date)
        }

        func date(from text: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return withFractional.date(from: text) ?? withoutFractional.date(from: text)
        }
    }

    public static func string(from date: Date) -> String {
        Formatters.shared.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        Formatters.shared.date(from: string)
    }

    /// Encoder every package writer should use.
    public static func encoder(sortedKeys: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        if sortedKeys {
            // Byte-stable output keeps a journal diffable between field tests.
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }

    /// Decoder every package reader should use.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let parsed = date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Not an ISO 8601 timestamp: \(raw)"
                )
            }
            return parsed
        }
        return decoder
    }
}
