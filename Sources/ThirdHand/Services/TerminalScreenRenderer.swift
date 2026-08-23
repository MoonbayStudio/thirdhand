import Foundation

/// Reconstructs the visible portion of a small VT100-style terminal screen.
///
/// Bubble Tea applications such as Antigravity redraw the same rows with cursor
/// movement commands. Removing ANSI sequences therefore produces a misleading
/// transcript. This renderer intentionally implements only the terminal
/// operations needed to recover readable, current screen text.
struct TerminalScreenRenderer {
    private let rows: Int
    private let columns: Int
    private var cells: [[Unicode.Scalar]]
    private var row = 0
    private var column = 0
    private var savedRow = 0
    private var savedColumn = 0

    init(rows: Int, columns: Int) {
        self.rows = max(rows, 1)
        self.columns = max(columns, 1)
        cells = Array(
            repeating: Array(repeating: " ", count: max(columns, 1)),
            count: max(rows, 1)
        )
    }

    static func render(
        _ value: String,
        rows: Int = 60,
        columns: Int = 120
    ) -> String {
        var renderer = Self(rows: rows, columns: columns)
        renderer.consume(value)
        return renderer.visibleText
    }

    mutating func consume(_ value: String) {
        let scalars = Array(value.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            switch scalar.value {
            case 0x1B:
                index = consumeEscapeSequence(in: scalars, startingAt: index)
            case 0x0D:
                column = 0
            case 0x0A:
                moveToNextLine()
            case 0x08:
                column = max(0, column - 1)
            case 0x09:
                column = min(columns - 1, ((column / 8) + 1) * 8)
            case 0x20...0x10_FFFF:
                put(scalar)
            default:
                break
            }

            index += 1
        }
    }

    var visibleText: String {
        var lines = cells.map { row in
            String(String.UnicodeScalarView(row))
                .replacingOccurrences(
                    of: #"\s+$"#,
                    with: "",
                    options: .regularExpression
                )
        }

        while lines.first?.isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private mutating func consumeEscapeSequence(
        in scalars: [Unicode.Scalar],
        startingAt index: Int
    ) -> Int {
        guard index + 1 < scalars.count else { return index }
        let next = scalars[index + 1]

        switch next.value {
        case 0x5B:
            return consumeCSI(in: scalars, startingAt: index + 2)
        case 0x5D:
            return consumeOSC(in: scalars, startingAt: index + 2)
        case 0x37:
            savedRow = row
            savedColumn = column
            return index + 1
        case 0x38:
            row = savedRow
            column = savedColumn
            return index + 1
        case 0x28, 0x29:
            return min(index + 2, scalars.count - 1)
        default:
            return index + 1
        }
    }

    private mutating func consumeCSI(
        in scalars: [Unicode.Scalar],
        startingAt start: Int
    ) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            if (0x40...0x7E).contains(value) {
                let parameterText = String(
                    String.UnicodeScalarView(scalars[start..<index])
                )
                applyCSI(parameters: parameterText, command: scalars[index])
                return index
            }
            index += 1
        }
        return scalars.count - 1
    }

    private func consumeOSC(
        in scalars: [Unicode.Scalar],
        startingAt start: Int
    ) -> Int {
        var index = start
        while index < scalars.count {
            if scalars[index].value == 0x07 {
                return index
            }
            if scalars[index].value == 0x1B,
               index + 1 < scalars.count,
               scalars[index + 1].value == 0x5C {
                return index + 1
            }
            index += 1
        }
        return scalars.count - 1
    }

    private mutating func applyCSI(
        parameters text: String,
        command: Unicode.Scalar
    ) {
        let isPrivate = text.hasPrefix("?")
        let values = text
            .trimmingCharacters(in: CharacterSet(charactersIn: "?><!"))
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        let first = values.first ?? 0
        let count = max(first, 1)

        switch command.value {
        case 0x41:
            row = max(0, row - count)
        case 0x42:
            row = min(rows - 1, row + count)
        case 0x43:
            column = min(columns - 1, column + count)
        case 0x44:
            column = max(0, column - count)
        case 0x45:
            row = min(rows - 1, row + count)
            column = 0
        case 0x46:
            row = max(0, row - count)
            column = 0
        case 0x47:
            column = clampedColumn(max(first, 1) - 1)
        case 0x48, 0x66:
            row = clampedRow(max(values[safe: 0] ?? 1, 1) - 1)
            column = clampedColumn(max(values[safe: 1] ?? 1, 1) - 1)
        case 0x64:
            row = clampedRow(max(first, 1) - 1)
        case 0x4A:
            eraseDisplay(mode: first)
        case 0x4B:
            eraseLine(mode: first)
        case 0x53:
            scrollUp(count)
        case 0x54:
            scrollDown(count)
        case 0x58:
            eraseCharacters(count)
        case 0x40:
            insertCharacters(count)
        case 0x50:
            deleteCharacters(count)
        case 0x73:
            savedRow = row
            savedColumn = column
        case 0x75:
            row = savedRow
            column = savedColumn
        case 0x68 where isPrivate && values.contains(1049):
            clear()
        default:
            break
        }
    }

    private mutating func put(_ scalar: Unicode.Scalar) {
        cells[row][column] = scalar
        if column == columns - 1 {
            column = 0
            moveToNextLine()
        } else {
            column += 1
        }
    }

    private mutating func moveToNextLine() {
        if row == rows - 1 {
            scrollUp(1)
        } else {
            row += 1
        }
    }

    private mutating func eraseDisplay(mode: Int) {
        switch mode {
        case 1:
            for targetRow in 0...row {
                let end = targetRow == row ? column : columns - 1
                for targetColumn in 0...end {
                    cells[targetRow][targetColumn] = " "
                }
            }
        case 2, 3:
            clear()
        default:
            for targetRow in row..<rows {
                let start = targetRow == row ? column : 0
                guard start < columns else { continue }
                for targetColumn in start..<columns {
                    cells[targetRow][targetColumn] = " "
                }
            }
        }
    }

    private mutating func eraseLine(mode: Int) {
        switch mode {
        case 1:
            for targetColumn in 0...column {
                cells[row][targetColumn] = " "
            }
        case 2:
            cells[row] = blankRow
        default:
            for targetColumn in column..<columns {
                cells[row][targetColumn] = " "
            }
        }
    }

    private mutating func eraseCharacters(_ count: Int) {
        for targetColumn in column..<min(columns, column + count) {
            cells[row][targetColumn] = " "
        }
    }

    private mutating func insertCharacters(_ count: Int) {
        let amount = min(count, columns - column)
        guard amount > 0 else { return }
        for targetColumn in stride(
            from: columns - 1,
            through: column + amount,
            by: -1
        ) {
            cells[row][targetColumn] = cells[row][targetColumn - amount]
        }
        for targetColumn in column..<column + amount {
            cells[row][targetColumn] = " "
        }
    }

    private mutating func deleteCharacters(_ count: Int) {
        let amount = min(count, columns - column)
        guard amount > 0 else { return }
        for targetColumn in column..<(columns - amount) {
            cells[row][targetColumn] = cells[row][targetColumn + amount]
        }
        for targetColumn in (columns - amount)..<columns {
            cells[row][targetColumn] = " "
        }
    }

    private mutating func scrollUp(_ count: Int) {
        for _ in 0..<min(count, rows) {
            cells.removeFirst()
            cells.append(blankRow)
        }
    }

    private mutating func scrollDown(_ count: Int) {
        for _ in 0..<min(count, rows) {
            cells.removeLast()
            cells.insert(blankRow, at: 0)
        }
    }

    private mutating func clear() {
        cells = Array(repeating: blankRow, count: rows)
        row = 0
        column = 0
    }

    private var blankRow: [Unicode.Scalar] {
        Array(repeating: " ", count: columns)
    }

    private func clampedRow(_ value: Int) -> Int {
        min(max(value, 0), rows - 1)
    }

    private func clampedColumn(_ value: Int) -> Int {
        min(max(value, 0), columns - 1)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
