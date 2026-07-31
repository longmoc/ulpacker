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

        case .table(let table):
            // Scrolls sideways rather than squeezing. A day's timing table has
            // four columns and a phone that shrinks them to fit turns the one
            // thing worth reading at a glance into something nobody can.
            //
            // A Grid, not a stack of rows: rows laid out independently size
            // their own cells, so "Aiguille Noire" widened one row's second
            // column and "Dolonne" narrowed the next, and the dividers came out
            // ragged. Grid gives every row the same columns.
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                            cellView(cell, table: table, index: index, isHeader: true)
                                .gridColumnAlignment(columnAlignment(table.alignment(at: index)))
                        }
                    }
                    .background(Color.primary.opacity(0.05))

                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                        Divider().gridCellColumns(max(1, table.header.count))
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                                cellView(cell, table: table, index: index, isHeader: false)
                            }
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .padding(.vertical, 2)
                .padding(.trailing, 2)
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    marker("\(index + 1).", item)
                }
            }
        }
    }

    private func cellView(
        _ text: String, table: Table, index: Int, isHeader: Bool
    ) -> some View {
        Text(inline(text))
            .font(isHeader ? font.weight(.semibold) : font)
            .foregroundStyle(isHeader ? Color.primary : Color.subtle)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: frameAlignment(table.alignment(at: index)))
            // The column rule hangs off the cell rather than being a column of
            // its own, so the Grid still has one column per column of data.
            .overlay(alignment: .leading) {
                if index > 0 {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                }
            }
    }

    private func textAlignment(_ alignment: Table.Alignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func columnAlignment(_ alignment: Table.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ alignment: Table.Alignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
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
        case table(Table)
    }

    /// A pipe table, kept as rows of cells with the alignment the author wrote.
    struct Table: Equatable {
        var header: [String]
        var rows: [[String]]
        var alignments: [Alignment]

        enum Alignment: Equatable { case leading, center, trailing }

        /// Rows are sometimes short of the header; treat the missing ones as
        /// left-aligned rather than losing the cell.
        func alignment(at index: Int) -> Alignment {
            index < alignments.count ? alignments[index] : .leading
        }
    }

    /// Split a note into blocks.
    ///
    /// Deliberately small: these notes are written by hand in a planner, not
    /// generated, and they use a handful of constructs. Anything unrecognised
    /// stays a paragraph, which is the one failure mode that cannot lose text.
    /// A header row, a separator that says how each column is aligned, and the
    /// body. Anything that does not have those first two is not a table.
    static func table(from lines: [String]) -> Table? {
        guard lines.count >= 2 else { return nil }
        let rows = lines.map(cells)
        let separator = rows[1]
        guard separator.allSatisfy({ cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= 3
                && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }) else { return nil }

        let alignments = separator.map { cell -> Table.Alignment in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let left = trimmed.hasPrefix(":")
            let right = trimmed.hasSuffix(":")
            if left && right { return .center }
            return right ? .trailing : .leading
        }
        return Table(header: rows[0], rows: Array(rows.dropFirst(2)), alignments: alignments)
    }

    /// Split one `| a | b |` line. Leading and trailing pipes are optional in
    /// the format and present in every note here, so both are dropped.
    private static func cells(_ line: String) -> [String] {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var tableLines: [String] = []

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
            if !tableLines.isEmpty {
                if let table = Self.table(from: tableLines) {
                    blocks.append(.table(table))
                } else {
                    // Not a table after all — pipes in ordinary prose. Better a
                    // paragraph with pipes in it than text that vanishes.
                    blocks.append(.paragraph(tableLines.joined(separator: " ")))
                }
                tableLines = []
            }
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

            if line.hasPrefix("|") {
                if !paragraph.isEmpty || !quote.isEmpty || !bullets.isEmpty || !numbers.isEmpty {
                    flush()
                }
                tableLines.append(line)
                continue
            }
            if !tableLines.isEmpty { flush() }

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
