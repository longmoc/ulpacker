import SwiftUI

/// A planner's note, rendered with its structure intact.
///
/// The notes are Markdown and they use it: headings to separate the parts of a
/// day, blockquotes for the thing that must not be missed, rules between
/// sections, bulleted and numbered lists for what to carry and in what order.
///
/// `Text(AttributedString(markdown:))` cannot show any of that. Parsing with
/// `.full` records the block structure in `presentationIntent`, but `Text`
/// renders none of it — and parsing inline-only, which is what this app did,
/// leaves `---` and `##` on screen as the literal characters somebody typed to
/// mean something else. So the blocks are split out here and each one becomes
/// its own view, with inline emphasis and links still handled by Foundation.
struct MarkdownNote: View {
    let text: String
    /// Paragraph font. Headings and captions size themselves from it.
    var font: Font = .subheadline
    /// Cap on blocks shown, for places where a note is context rather than the
    /// content. Nil shows all of it.
    var blockLimit: Int?

    var body: some View {
        let blocks = Self.parse(text)
        let shown = blockLimit.map { Array(blocks.prefix($0)) } ?? blocks
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rendering

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(inline(text))
                .font(font)
                .fixedSize(horizontal: false, vertical: true)

        case .quote(let text):
            // A bar rather than an indent: on a phone the indent alone is too
            // easy to miss, and a quote in these notes is usually the sentence
            // the day turns on.
            HStack(alignment: .top, spacing: 8) {
                Capsule()
                    .fill(Color.brand.opacity(0.55))
                    .frame(width: 3)
                Text(inline(text))
                    .font(font)
                    .foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Divider()

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    marker("•", item)
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    marker("\(index + 1).", item)
                }
            }
        }
    }

    private func marker(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(symbol)
                .font(font.weight(.semibold))
                .foregroundStyle(Color.subtle)
                .frame(minWidth: 14, alignment: .trailing)
            Text(inline(text))
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .headline
        case 2: .subheadline.weight(.semibold)
        default: .footnote.weight(.semibold)
        }
    }

    /// Emphasis, code and links, left to Foundation. Only the block structure
    /// needed doing by hand.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: - Parsing

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case quote(String)
        case rule
        case bullet([String])
        case numbered([String])
    }

    /// Split a note into blocks.
    ///
    /// Deliberately small: these notes are written by hand in a planner, not
    /// generated, and they use a handful of constructs. Anything unrecognised
    /// stays a paragraph, which is the one failure mode that cannot lose text.
    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: " ")))
                quote = []
            }
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { flush(); continue }

            if line.allSatisfy({ $0 == "-" }) && line.count >= 3
                || line.allSatisfy({ $0 == "*" }) && line.count >= 3
                || line.allSatisfy({ $0 == "_" }) && line.count >= 3 {
                flush()
                // A rule at the very top is a separator from nothing; the
                // planner writes one there and it reads as a stray line.
                if !blocks.isEmpty { blocks.append(.rule) }
                continue
            }

            if let hashes = line.prefix(while: { $0 == "#" }).count as Int?,
               hashes >= 1, hashes <= 6, line.dropFirst(hashes).first == " " {
                flush()
                blocks.append(.heading(
                    level: hashes,
                    text: String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                ))
                continue
            }

            if line.hasPrefix("> ") || line == ">" {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbers.isEmpty { flush() }
                quote.append(String(line.dropFirst(line == ">" ? 1 : 2)))
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                if !paragraph.isEmpty || !quote.isEmpty || !numbers.isEmpty { flush() }
                bullets.append(String(line.dropFirst(2)))
                continue
            }

            if let dot = line.firstIndex(of: "."),
               line[line.startIndex..<dot].allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex,
               line[line.index(after: dot)] == " " {
                if !paragraph.isEmpty || !quote.isEmpty || !bullets.isEmpty { flush() }
                numbers.append(String(line[line.index(dot, offsetBy: 2)...]))
                continue
            }

            if !quote.isEmpty || !bullets.isEmpty || !numbers.isEmpty { flush() }
            paragraph.append(line)
        }
        flush()
        return blocks
    }
}
