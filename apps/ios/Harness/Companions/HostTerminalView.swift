// Live host terminals over DeviceRelayClient (OpenTerminal / SubscribeTerminal /
// WriteTerminal / ResizeTerminal / CloseTerminal) + VT100/ANSI screen buffer,
// CoreGraphics box/block glyph renderer, TerminalKeyBar, and offline demo shell.

import Foundation
import Observation
import SwiftUI
import UIKit

// MARK: - Wire Protocol (crates/proto/src/entities.rs + crates/engine/src/rpc.rs)

enum TerminalRpcMethod {
    static let open = "OpenTerminal"
    static let subscribe = "SubscribeTerminal"
    static let write = "WriteTerminal"
    static let resize = "ResizeTerminal"
    static let close = "CloseTerminal"
}

struct OpenTerminalParams: Codable, Equatable, Sendable {
    var chatId: String
    var cols: UInt16
    var rows: UInt16
    var cwd: String?

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = ["chatId": chatId, "cols": Int(cols), "rows": Int(rows)]
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["cwd"] = cwd
        }
        return dict
    }
}

struct SubscribeTerminalParams: Codable, Equatable, Sendable {
    var terminalId: String
    var afterSeq: UInt64?

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = ["terminalId": terminalId]
        if let afterSeq { dict["afterSeq"] = afterSeq }
        return dict
    }
}

struct WriteTerminalParams: Codable, Equatable, Sendable {
    var terminalId: String
    /// Base64-encoded input bytes (crates/engine/src/terminals.rs `write`).
    var data: String

    init(terminalId: String, rawBytes: Data) {
        self.terminalId = terminalId
        self.data = rawBytes.base64EncodedString()
    }

    init(terminalId: String, data: String) {
        self.terminalId = terminalId
        self.data = data
    }

    func toDictionary() -> [String: Any] {
        ["terminalId": terminalId, "data": data]
    }
}

struct ResizeTerminalParams: Codable, Equatable, Sendable {
    var terminalId: String
    var cols: UInt16
    var rows: UInt16

    func toDictionary() -> [String: Any] {
        ["terminalId": terminalId, "cols": Int(cols), "rows": Int(rows)]
    }
}

struct CloseTerminalParams: Codable, Equatable, Sendable {
    var terminalId: String

    func toDictionary() -> [String: Any] {
        ["terminalId": terminalId]
    }
}

struct TerminalOkReply: Codable, Equatable, Sendable {
    var ok: Bool
}

struct TerminalSessionWire: Codable, Equatable, Sendable {
    var id: String
    var cwd: String
    var shell: String
}

enum TerminalEventWire: Codable, Equatable, Sendable {
    case data(seq: UInt64, data: String)
    case exit(seq: UInt64, exitCode: Int32, signal: String?)

    private enum CodingKeys: String, CodingKey {
        case type, seq, data, exitCode, signal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .type)
        let seq = try c.decode(UInt64.self, forKey: .seq)
        switch kind {
        case "data":
            let payload = try c.decode(String.self, forKey: .data)
            self = .data(seq: seq, data: payload)
        case "exit":
            let code = try c.decode(Int32.self, forKey: .exitCode)
            let sig = try c.decodeIfPresent(String.self, forKey: .signal)
            self = .exit(seq: seq, exitCode: code, signal: sig)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown TerminalEvent type: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .data(let seq, let data):
            try c.encode("data", forKey: .type)
            try c.encode(seq, forKey: .seq)
            try c.encode(data, forKey: .data)
        case .exit(let seq, let exitCode, let signal):
            try c.encode("exit", forKey: .type)
            try c.encode(seq, forKey: .seq)
            try c.encode(exitCode, forKey: .exitCode)
            try c.encodeIfPresent(signal, forKey: .signal)
        }
    }

    var seq: UInt64 {
        switch self {
        case .data(let seq, _), .exit(let seq, _, _): return seq
        }
    }

    var decodedBytes: Data? {
        guard case .data(_, let b64) = self else { return nil }
        return Data(base64Encoded: b64)
    }
}

struct HostTerminalSessionInfo: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let chatId: String
    let deviceId: String
    let cwd: String
    let shell: String
    var exited: Bool
    var exitCode: Int32?
    var signal: String?
    var lastSeq: UInt64

    var isLive: Bool { !exited }
}

// MARK: - Terminal Color, Attributes, Glyphs & Screen Buffer

enum TerminalColor: Equatable, Hashable, Sendable {
    case defaultForeground
    case defaultBackground
    case ansi(UInt8)
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    func resolvedUIColor(isDark: Bool, isForeground: Bool) -> UIColor {
        switch self {
        case .defaultForeground:
            return UIColor(Theme.text)
        case .defaultBackground:
            return UIColor(Theme.bg)
        case .ansi(let index):
            return Self.ansiColor(index, isDark: isDark)
        case .indexed(let index):
            if index < 16 { return Self.ansiColor(index, isDark: isDark) }
            if index < 232 {
                let n = Int(index) - 16
                let r = n / 36
                let g = (n % 36) / 6
                let b = n % 6
                func level(_ v: Int) -> CGFloat { v == 0 ? 0 : CGFloat(55 + v * 40) / 255.0 }
                return UIColor(red: level(r), green: level(g), blue: level(b), alpha: 1)
            }
            let gray = CGFloat(8 + (Int(index) - 232) * 10) / 255.0
            return UIColor(red: gray, green: gray, blue: gray, alpha: 1)
        case .rgb(let r, let g, let b):
            return UIColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1)
        }
    }

    private static func ansiColor(_ index: UInt8, isDark: Bool) -> UIColor {
        let darkTable: [(UInt8, UInt8, UInt8)] = [
            (0x27, 0x27, 0x2A), (0xEF, 0x44, 0x44), (0x22, 0xC5, 0x5E), (0xEA, 0xB3, 0x08),
            (0x3B, 0x82, 0xF6), (0xA8, 0x55, 0xF7), (0x06, 0xB6, 0xD4), (0xE4, 0xE4, 0xE7),
            (0x71, 0x71, 0x7A), (0xF8, 0x71, 0x71), (0x4A, 0xDE, 0x80), (0xFA, 0xCC, 0x15),
            (0x60, 0xA5, 0xFA), (0xC0, 0x84, 0xFC), (0x22, 0xD3, 0xEE), (0xFF, 0xFF, 0xFF),
        ]
        let lightTable: [(UInt8, UInt8, UInt8)] = [
            (0x18, 0x18, 0x1B), (0xDC, 0x26, 0x26), (0x16, 0xA3, 0x4A), (0xCA, 0x8A, 0x04),
            (0x25, 0x63, 0xEB), (0x93, 0x33, 0xEA), (0x08, 0x91, 0xB2), (0x52, 0x52, 0x5B),
            (0x71, 0x71, 0x7A), (0xEF, 0x44, 0x44), (0x22, 0xC5, 0x5E), (0xD9, 0x77, 0x06),
            (0x3B, 0x82, 0xF6), (0xA8, 0x55, 0xF7), (0x06, 0xB6, 0xD4), (0x09, 0x09, 0x0B),
        ]
        let entry = (isDark ? darkTable : lightTable)[Int(index % 16)]
        return UIColor(red: CGFloat(entry.0) / 255.0,
                       green: CGFloat(entry.1) / 255.0,
                       blue: CGFloat(entry.2) / 255.0,
                       alpha: 1)
    }
}

struct TerminalAttributes: Equatable, Hashable, Sendable {
    var foreground: TerminalColor = .defaultForeground
    var background: TerminalColor = .defaultBackground
    var bold: Bool = false
    var dim: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var inverse: Bool = false

    static let `default` = TerminalAttributes()
}

struct TerminalCell: Equatable, Hashable, Sendable {
    var scalar: Unicode.Scalar
    var attributes: TerminalAttributes
    var width: UInt8

    static let blank = TerminalCell(scalar: " ", attributes: .default, width: 1)
}

enum TerminalGlyphKind: Equatable, Sendable {
    case text
    case boxDrawing
    case blockElement

    static func classify(_ scalar: Unicode.Scalar) -> TerminalGlyphKind {
        let v = scalar.value
        if (0x2500...0x257F).contains(v) { return .boxDrawing }
        if (0x2580...0x259F).contains(v) { return .blockElement }
        return .text
    }
}

/// Pure ANSI / VT100 terminal screen buffer supporting SGR 16/256/truecolor,
/// cursor movement, line/screen clearing, scrollback, and alternate screens.
final class TerminalScreenBuffer {
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var cursorRow: Int = 0
    private(set) var cursorCol: Int = 0
    private(set) var currentAttributes: TerminalAttributes = .default
    private(set) var grid: [[TerminalCell]]
    private(set) var scrollback: [[TerminalCell]] = []
    private(set) var isAlternateScreen: Bool = false
    private(set) var cursorVisible: Bool = true
    private(set) var title: String?

    let maxScrollback: Int

    private var savedCursor: (row: Int, col: Int, attrs: TerminalAttributes) = (0, 0, .default)
    private var primaryGrid: [[TerminalCell]]?
    private var primaryCursor: (row: Int, col: Int, attrs: TerminalAttributes)?
    private var scrollTop: Int
    private var scrollBottom: Int
    private var pendingWrap: Bool = false

    private enum ParseState {
        case ground
        case escape
        case csi(String)
        case osc(String)
        case oscEscape(String)
        case charset
    }

    private var parseState: ParseState = .ground
    private var utf8Pending: [UInt8] = []

    init(cols: Int = 80, rows: Int = 24, maxScrollback: Int = 1000) {
        self.cols = max(2, min(500, cols))
        self.rows = max(1, min(300, rows))
        self.maxScrollback = max(0, maxScrollback)
        self.scrollTop = 0
        self.scrollBottom = self.rows - 1
        self.grid = Self.makeGrid(cols: self.cols, rows: self.rows)
    }

    private static func makeRow(cols: Int, attributes: TerminalAttributes = .default) -> [TerminalCell] {
        Array(repeating: TerminalCell(scalar: " ", attributes: attributes, width: 1), count: cols)
    }

    private static func makeGrid(cols: Int, rows: Int) -> [[TerminalCell]] {
        (0..<rows).map { _ in makeRow(cols: cols) }
    }

    func cellAt(row: Int, col: Int) -> TerminalCell {
        guard row >= 0, row < rows, col >= 0, col < cols else { return .blank }
        return grid[row][col]
    }

    func lineText(row: Int) -> String {
        guard row >= 0, row < rows else { return "" }
        return Self.rowString(grid[row])
    }

    func plainText(includeScrollback: Bool = false) -> String {
        let lines: [[TerminalCell]] = includeScrollback ? (scrollback + grid) : grid
        var strings = lines.map(Self.rowString)
        while let last = strings.last, last.isEmpty {
            strings.removeLast()
        }
        return strings.joined(separator: "\n")
    }

    private static func rowString(_ row: [TerminalCell]) -> String {
        var out = ""
        for cell in row where cell.width > 0 {
            out.unicodeScalars.append(cell.scalar)
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        let targetCols = max(2, min(500, newCols))
        let targetRows = max(1, min(300, newRows))
        guard targetCols != cols || targetRows != rows else { return }

        var nextGrid = Self.makeGrid(cols: targetCols, rows: targetRows)
        let copyRows = min(rows, targetRows)
        let copyCols = min(cols, targetCols)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                nextGrid[r][c] = grid[r][c]
            }
        }
        grid = nextGrid
        cols = targetCols
        rows = targetRows
        scrollTop = 0
        scrollBottom = targetRows - 1
        cursorRow = min(max(0, cursorRow), targetRows - 1)
        cursorCol = min(max(0, cursorCol), targetCols - 1)
        pendingWrap = false
    }

    func feed(_ string: String) {
        feed(Data(string.utf8))
    }

    func feed(_ data: Data) {
        for byte in data {
            consumeByte(byte)
        }
    }

    private func consumeByte(_ byte: UInt8) {
        if !utf8Pending.isEmpty {
            if (byte & 0xC0) == 0x80 {
                utf8Pending.append(byte)
                let expected = utf8ExpectedLength(utf8Pending[0])
                if utf8Pending.count == expected {
                    if let s = String(bytes: utf8Pending, encoding: .utf8),
                       let scalar = s.unicodeScalars.first {
                        utf8Pending.removeAll(keepingCapacity: true)
                        processScalar(scalar)
                    } else {
                        utf8Pending.removeAll(keepingCapacity: true)
                    }
                }
                return
            } else {
                utf8Pending.removeAll(keepingCapacity: true)
            }
        }

        if byte >= 0xC0 {
            let expected = utf8ExpectedLength(byte)
            if expected > 1 {
                utf8Pending.append(byte)
                return
            }
        }

        if byte < 0x80 {
            processScalar(Unicode.Scalar(byte))
        }
    }

    private func utf8ExpectedLength(_ lead: UInt8) -> Int {
        if (lead & 0xE0) == 0xC0 { return 2 }
        if (lead & 0xF0) == 0xE0 { return 3 }
        if (lead & 0xF8) == 0xF0 { return 4 }
        return 1
    }

    private func processScalar(_ scalar: Unicode.Scalar) {
        switch parseState {
        case .ground:
            processGround(scalar)
        case .escape:
            processEscape(scalar)
        case .csi(var buf):
            let v = scalar.value
            if v >= 0x40 && v <= 0x7E {
                parseState = .ground
                processCsi(params: buf, final: scalar)
            } else if v == 0x1B {
                parseState = .escape
            } else {
                buf.unicodeScalars.append(scalar)
                parseState = .csi(buf)
            }
        case .osc(var buf):
            if scalar.value == 0x07 {
                finishOsc(buf)
                parseState = .ground
            } else if scalar.value == 0x1B {
                parseState = .oscEscape(buf)
            } else {
                buf.unicodeScalars.append(scalar)
                parseState = .osc(buf)
            }
        case .oscEscape(let buf):
            if scalar == "\\" {
                finishOsc(buf)
                parseState = .ground
            } else {
                parseState = .ground
                processEscape(scalar)
            }
        case .charset:
            parseState = .ground
        }
    }

    private func finishOsc(_ body: String) {
        if let semi = body.firstIndex(of: ";"),
           let code = Int(body[..<semi]),
           code == 0 || code == 2 {
            title = String(body[body.index(after: semi)...])
        }
    }

    private func processGround(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x00...0x06, 0x0E...0x1A, 0x1C...0x1F, 0x7F:
            break
        case 0x07: // BEL
            break
        case 0x08: // BS
            pendingWrap = false
            cursorCol = max(0, cursorCol - 1)
        case 0x09: // TAB
            pendingWrap = false
            cursorCol = min(cols - 1, ((cursorCol / 8) + 1) * 8)
        case 0x0A, 0x0B, 0x0C: // LF / VT / FF
            lineFeed()
        case 0x0D: // CR
            pendingWrap = false
            cursorCol = 0
        case 0x1B: // ESC
            parseState = .escape
        default:
            putScalar(scalar)
        }
    }

    private func processEscape(_ scalar: Unicode.Scalar) {
        switch scalar {
        case "[":
            parseState = .csi("")
        case "]":
            parseState = .osc("")
        case "(", ")", "*", "+":
            parseState = .charset
        case "7":
            savedCursor = (cursorRow, cursorCol, currentAttributes)
            parseState = .ground
        case "8":
            cursorRow = min(rows - 1, max(0, savedCursor.row))
            cursorCol = min(cols - 1, max(0, savedCursor.col))
            currentAttributes = savedCursor.attrs
            pendingWrap = false
            parseState = .ground
        case "M":
            reverseIndex()
            parseState = .ground
        case "c":
            resetAll()
            parseState = .ground
        default:
            parseState = .ground
        }
    }

    private func putScalar(_ scalar: Unicode.Scalar) {
        if pendingWrap {
            cursorCol = 0
            lineFeed()
        }
        guard cursorRow >= 0, cursorRow < rows, cursorCol >= 0, cursorCol < cols else { return }
        grid[cursorRow][cursorCol] = TerminalCell(scalar: scalar, attributes: currentAttributes, width: 1)
        if cursorCol == cols - 1 {
            pendingWrap = true
        } else {
            cursorCol += 1
        }
    }

    private func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom {
            scrollUp(top: scrollTop, bottom: scrollBottom, count: 1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursorRow == scrollTop {
            scrollDown(top: scrollTop, bottom: scrollBottom, count: 1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func scrollUp(top: Int, bottom: Int, count: Int) {
        guard top >= 0, bottom < rows, top <= bottom, count > 0 else { return }
        let n = min(count, bottom - top + 1)
        if !isAlternateScreen && top == 0 && maxScrollback > 0 {
            for r in 0..<n {
                scrollback.append(grid[r])
            }
            if scrollback.count > maxScrollback {
                scrollback.removeFirst(scrollback.count - maxScrollback)
            }
        }
        for r in top...(bottom - n) where r + n <= bottom {
            grid[r] = grid[r + n]
        }
        for r in (bottom - n + 1)...bottom {
            grid[r] = Self.makeRow(cols: cols, attributes: clearAttributes())
        }
    }

    private func scrollDown(top: Int, bottom: Int, count: Int) {
        guard top >= 0, bottom < rows, top <= bottom, count > 0 else { return }
        let n = min(count, bottom - top + 1)
        for r in stride(from: bottom, through: top + n, by: -1) {
            grid[r] = grid[r - n]
        }
        for r in top..<(top + n) {
            grid[r] = Self.makeRow(cols: cols, attributes: clearAttributes())
        }
    }

    private func clearAttributes() -> TerminalAttributes {
        var attrs = TerminalAttributes.default
        attrs.background = currentAttributes.background
        return attrs
    }

    private func resetAll() {
        currentAttributes = .default
        grid = Self.makeGrid(cols: cols, rows: rows)
        scrollback.removeAll()
        cursorRow = 0
        cursorCol = 0
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
        isAlternateScreen = false
        primaryGrid = nil
        primaryCursor = nil
        cursorVisible = true
    }

    private func processCsi(params raw: String, final: Unicode.Scalar) {
        let isPrivate = raw.hasPrefix("?")
        let stripped = isPrivate ? String(raw.dropFirst()) : raw
        let parts = stripped.isEmpty ? [String]() : stripped.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        func param(_ index: Int, default def: Int) -> Int {
            guard index < parts.count, !parts[index].isEmpty, let v = Int(parts[index]) else { return def }
            return v
        }

        if isPrivate {
            let modes = parts.compactMap { Int($0) }
            switch final {
            case "h":
                for mode in modes {
                    if mode == 1049 || mode == 1047 || mode == 47 {
                        enterAlternateScreen()
                    } else if mode == 25 {
                        cursorVisible = true
                    }
                }
            case "l":
                for mode in modes {
                    if mode == 1049 || mode == 1047 || mode == 47 {
                        exitAlternateScreen()
                    } else if mode == 25 {
                        cursorVisible = false
                    }
                }
            default:
                break
            }
            return
        }

        switch final {
        case "A":
            pendingWrap = false
            cursorRow = max(scrollTop, cursorRow - max(1, param(0, default: 1)))
        case "B":
            pendingWrap = false
            cursorRow = min(scrollBottom, cursorRow + max(1, param(0, default: 1)))
        case "C":
            pendingWrap = false
            cursorCol = min(cols - 1, cursorCol + max(1, param(0, default: 1)))
        case "D":
            pendingWrap = false
            cursorCol = max(0, cursorCol - max(1, param(0, default: 1)))
        case "E":
            pendingWrap = false
            cursorRow = min(scrollBottom, cursorRow + max(1, param(0, default: 1)))
            cursorCol = 0
        case "F":
            pendingWrap = false
            cursorRow = max(scrollTop, cursorRow - max(1, param(0, default: 1)))
            cursorCol = 0
        case "G", "`":
            pendingWrap = false
            cursorCol = min(cols - 1, max(0, param(0, default: 1) - 1))
        case "H", "f":
            pendingWrap = false
            cursorRow = min(rows - 1, max(0, param(0, default: 1) - 1))
            cursorCol = min(cols - 1, max(0, param(1, default: 1) - 1))
        case "d":
            pendingWrap = false
            cursorRow = min(rows - 1, max(0, param(0, default: 1) - 1))
        case "J":
            eraseDisplay(mode: param(0, default: 0))
        case "K":
            eraseLine(mode: param(0, default: 0))
        case "L":
            let count = max(1, param(0, default: 1))
            if cursorRow >= scrollTop && cursorRow <= scrollBottom {
                scrollDown(top: cursorRow, bottom: scrollBottom, count: count)
            }
        case "M":
            let count = max(1, param(0, default: 1))
            if cursorRow >= scrollTop && cursorRow <= scrollBottom {
                scrollUp(top: cursorRow, bottom: scrollBottom, count: count)
            }
        case "P":
            let count = min(cols - cursorCol, max(1, param(0, default: 1)))
            for c in cursorCol..<(cols - count) {
                grid[cursorRow][c] = grid[cursorRow][c + count]
            }
            for c in (cols - count)..<cols {
                grid[cursorRow][c] = TerminalCell(scalar: " ", attributes: clearAttributes(), width: 1)
            }
        case "X":
            let count = min(cols - cursorCol, max(1, param(0, default: 1)))
            for c in cursorCol..<(cursorCol + count) {
                grid[cursorRow][c] = TerminalCell(scalar: " ", attributes: clearAttributes(), width: 1)
            }
        case "r":
            let top = max(1, param(0, default: 1)) - 1
            let bottom = min(rows, param(1, default: rows)) - 1
            if top < bottom {
                scrollTop = top
                scrollBottom = bottom
            }
            cursorRow = 0
            cursorCol = 0
            pendingWrap = false
        case "s":
            savedCursor = (cursorRow, cursorCol, currentAttributes)
        case "u":
            cursorRow = min(rows - 1, max(0, savedCursor.row))
            cursorCol = min(cols - 1, max(0, savedCursor.col))
            currentAttributes = savedCursor.attrs
            pendingWrap = false
        case "m":
            applySgr(parts)
        default:
            break
        }
    }

    private func enterAlternateScreen() {
        guard !isAlternateScreen else { return }
        primaryGrid = grid
        primaryCursor = (cursorRow, cursorCol, currentAttributes)
        isAlternateScreen = true
        grid = Self.makeGrid(cols: cols, rows: rows)
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
    }

    private func exitAlternateScreen() {
        guard isAlternateScreen else { return }
        isAlternateScreen = false
        if let saved = primaryGrid {
            grid = saved
            if grid.count != rows || (grid.first?.count ?? 0) != cols {
                let targetCols = cols, targetRows = rows
                cols = grid.first?.count ?? targetCols
                rows = grid.count
                resize(cols: targetCols, rows: targetRows)
            }
        }
        if let savedCur = primaryCursor {
            cursorRow = min(rows - 1, max(0, savedCur.row))
            cursorCol = min(cols - 1, max(0, savedCur.col))
            currentAttributes = savedCur.attrs
        }
        primaryGrid = nil
        primaryCursor = nil
        pendingWrap = false
    }

    private func eraseDisplay(mode: Int) {
        let blank = TerminalCell(scalar: " ", attributes: clearAttributes(), width: 1)
        switch mode {
        case 0:
            eraseLine(mode: 0)
            if cursorRow + 1 < rows {
                for r in (cursorRow + 1)..<rows {
                    grid[r] = Array(repeating: blank, count: cols)
                }
            }
        case 1:
            if cursorRow > 0 {
                for r in 0..<cursorRow {
                    grid[r] = Array(repeating: blank, count: cols)
                }
            }
            eraseLine(mode: 1)
        case 2, 3:
            grid = (0..<rows).map { _ in Array(repeating: blank, count: cols) }
            if mode == 3 { scrollback.removeAll() }
        default:
            break
        }
    }

    private func eraseLine(mode: Int) {
        let blank = TerminalCell(scalar: " ", attributes: clearAttributes(), width: 1)
        switch mode {
        case 0:
            for c in cursorCol..<cols { grid[cursorRow][c] = blank }
        case 1:
            for c in 0...min(cursorCol, cols - 1) { grid[cursorRow][c] = blank }
        case 2:
            grid[cursorRow] = Array(repeating: blank, count: cols)
        default:
            break
        }
    }

    private func applySgr(_ rawParts: [String]) {
        if rawParts.isEmpty || (rawParts.count == 1 && rawParts[0].isEmpty) {
            currentAttributes = .default
            return
        }
        // Flatten colon-separated extended colors (e.g. 38:5:196 or 38:2::r:g:b)
        var tokens: [Int] = []
        for part in rawParts {
            if part.isEmpty {
                tokens.append(0)
            } else if part.contains(":") {
                let sub = part.split(separator: ":", omittingEmptySubsequences: false)
                if sub.count >= 3, (sub[0] == "38" || sub[0] == "48"), sub[1] == "2" {
                    tokens.append(Int(sub[0]) ?? 0)
                    tokens.append(2)
                    // 38:2:colorspace:r:g:b (6 parts) or 38:2:r:g:b (5 parts)
                    let offset = sub.count >= 6 ? 3 : 2
                    for i in offset..<min(offset + 3, sub.count) {
                        tokens.append(Int(sub[i]) ?? 0)
                    }
                } else {
                    for s in sub { tokens.append(Int(s) ?? 0) }
                }
            } else if let n = Int(part) {
                tokens.append(n)
            }
        }

        var idx = 0
        while idx < tokens.count {
            let code = tokens[idx]
            switch code {
            case 0: currentAttributes = .default
            case 1: currentAttributes.bold = true
            case 2: currentAttributes.dim = true
            case 3: currentAttributes.italic = true
            case 4: currentAttributes.underline = true
            case 7: currentAttributes.inverse = true
            case 22: currentAttributes.bold = false; currentAttributes.dim = false
            case 23: currentAttributes.italic = false
            case 24: currentAttributes.underline = false
            case 27: currentAttributes.inverse = false
            case 30...37: currentAttributes.foreground = .ansi(UInt8(code - 30))
            case 39: currentAttributes.foreground = .defaultForeground
            case 40...47: currentAttributes.background = .ansi(UInt8(code - 40))
            case 49: currentAttributes.background = .defaultBackground
            case 90...97: currentAttributes.foreground = .ansi(UInt8(code - 90 + 8))
            case 100...107: currentAttributes.background = .ansi(UInt8(code - 100 + 8))
            case 38, 48:
                let isFg = code == 38
                if idx + 1 < tokens.count {
                    let mode = tokens[idx + 1]
                    if mode == 5, idx + 2 < tokens.count {
                        let c = TerminalColor.indexed(UInt8(clamping: tokens[idx + 2]))
                        if isFg { currentAttributes.foreground = c } else { currentAttributes.background = c }
                        idx += 2
                    } else if mode == 2, idx + 4 < tokens.count {
                        let c = TerminalColor.rgb(
                            UInt8(clamping: tokens[idx + 2]),
                            UInt8(clamping: tokens[idx + 3]),
                            UInt8(clamping: tokens[idx + 4])
                        )
                        if isFg { currentAttributes.foreground = c } else { currentAttributes.background = c }
                        idx += 4
                    }
                }
            default:
                break
            }
            idx += 1
        }
    }
}

// MARK: - Key Input Encoding

enum TerminalInputEncoder {
    static func encode(text: String, ctrl: Bool) -> (data: Data, consumedCtrl: Bool) {
        if text == "\n" {
            return (Data([0x0D]), false)
        }
        guard ctrl else {
            return (Data(text.utf8), false)
        }
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else {
            return (Data(text.utf8), true)
        }
        let v = scalar.value
        let byte: UInt8?
        switch v {
        case 0x40...0x5F: // @ A..Z [ \ ] ^ _
            byte = UInt8(v - 0x40)
        case 0x61...0x7A: // a..z
            byte = UInt8(v - 0x60)
        case 0x20: // Space -> NUL
            byte = 0x00
        case 0x3F: // ? -> DEL
            byte = 0x7F
        default:
            byte = nil
        }
        if let byte {
            return (Data([byte]), true)
        }
        return (Data(text.utf8), true)
    }
}

// MARK: - Store

@MainActor
@Observable
final class ManagedHostTerminal: Identifiable {
    let id: String
    var info: HostTerminalSessionInfo
    let screen: TerminalScreenBuffer
    var renderTick: UInt64 = 0
    var connecting: Bool
    var error: String?
    let isDemo: Bool

    @ObservationIgnored var streamTask: Task<Void, Never>?
    @ObservationIgnored var demoLineBuffer: String = ""
    @ObservationIgnored var demoHistory: [String] = []
    @ObservationIgnored var demoHistoryIndex: Int?
    @ObservationIgnored var closed = false

    init(info: HostTerminalSessionInfo, isDemo: Bool, cols: Int, rows: Int) {
        self.id = info.id
        self.info = info
        self.isDemo = isDemo
        self.connecting = !isDemo
        self.screen = TerminalScreenBuffer(cols: cols, rows: rows)
    }

    func markRendered() {
        renderTick &+= 1
    }
}

@MainActor
@Observable
final class HostTerminalStore {
    static let shared = HostTerminalStore()

    private(set) var terminalsByChat: [String: [ManagedHostTerminal]] = [:]
    private(set) var activeTerminalIdByChat: [String: String] = [:]
    private(set) var openingChatIds: Set<String> = []
    private(set) var lastErrorByChat: [String: String] = [:]

    init() {}

    func sessions(for chatId: String) -> [HostTerminalSessionInfo] {
        (terminalsByChat[chatId] ?? []).map(\.info)
    }

    var allSessions: [HostTerminalSessionInfo] {
        terminalsByChat.values.flatMap { $0.map(\.info) }
    }

    func activeTerminalId(for chatId: String) -> String? {
        if let id = activeTerminalIdByChat[chatId],
           terminalsByChat[chatId]?.contains(where: { $0.id == id }) == true {
            return id
        }
        return terminalsByChat[chatId]?.first?.id
    }

    func setActiveTerminal(_ terminalId: String, for chatId: String) {
        activeTerminalIdByChat[chatId] = terminalId
    }

    func terminal(id terminalId: String) -> ManagedHostTerminal? {
        for list in terminalsByChat.values {
            if let match = list.first(where: { $0.id == terminalId }) { return match }
        }
        return nil
    }

    @discardableResult
    func openTerminal(
        chat: Chat,
        cols: Int = 80,
        rows: Int = 24,
        model: AppModel
    ) async -> String? {
        guard !openingChatIds.contains(chat.id) else {
            return activeTerminalId(for: chat.id)
        }
        openingChatIds.insert(chat.id)
        lastErrorByChat[chat.id] = nil
        defer { openingChatIds.remove(chat.id) }

        let safeCols = max(20, min(500, cols))
        let safeRows = max(8, min(300, rows))

        if model.demo != nil {
            let id = "demo-term-\(UUID().uuidString.lowercased().prefix(6))"
            let cwd = chat.cwd ?? "/Users/dev/harness"
            let info = HostTerminalSessionInfo(
                id: id, chatId: chat.id, deviceId: chat.deviceId,
                cwd: cwd, shell: "zsh", exited: false, exitCode: nil, signal: nil, lastSeq: 0
            )
            let managed = ManagedHostTerminal(info: info, isDemo: true, cols: safeCols, rows: safeRows)
            seedDemoBanner(managed, chat: chat)
            terminalsByChat[chat.id, default: []].append(managed)
            activeTerminalIdByChat[chat.id] = id
            return id
        }

        guard let workspace = model.workspace else {
            lastErrorByChat[chat.id] = RelayError.notConnected.errorDescription
            return nil
        }

        let params = OpenTerminalParams(
            chatId: chat.id,
            cols: UInt16(safeCols),
            rows: UInt16(safeRows),
            cwd: chat.cwd
        )
        do {
            let wire: TerminalSessionWire = try await workspace.relay(for: chat.deviceId)
                .call(method: TerminalRpcMethod.open,
                      params: params.toDictionary(),
                      timeoutSeconds: 15,
                      retry: false)
            let info = HostTerminalSessionInfo(
                id: wire.id,
                chatId: chat.id,
                deviceId: chat.deviceId,
                cwd: wire.cwd,
                shell: wire.shell,
                exited: false,
                exitCode: nil,
                signal: nil,
                lastSeq: 0
            )
            let managed = ManagedHostTerminal(info: info, isDemo: false, cols: safeCols, rows: safeRows)
            terminalsByChat[chat.id, default: []].append(managed)
            activeTerminalIdByChat[chat.id] = wire.id
            startSubscription(managed, model: model)
            return wire.id
        } catch {
            lastErrorByChat[chat.id] = describeUserFacingError(error)
            return nil
        }
    }

    func reconnect(terminalId: String, model: AppModel) {
        guard let managed = terminal(id: terminalId), !managed.isDemo, !managed.info.exited else { return }
        managed.streamTask?.cancel()
        managed.error = nil
        startSubscription(managed, model: model)
    }

    private func startSubscription(_ managed: ManagedHostTerminal, model: AppModel) {
        managed.streamTask?.cancel()
        managed.streamTask = Task { [weak self, weak managed, weak model] in
            var backoffNs: UInt64 = 500_000_000
            while !Task.isCancelled {
                guard let self, let managed, let model, !managed.closed, !managed.info.exited else { return }
                guard let workspace = model.workspace else {
                    managed.connecting = false
                    managed.error = RelayError.notConnected.errorDescription
                    return
                }
                managed.connecting = true
                let afterSeq: UInt64? = managed.info.lastSeq > 0 ? managed.info.lastSeq : nil
                let params = SubscribeTerminalParams(terminalId: managed.id, afterSeq: afterSeq)
                do {
                    let stream: AsyncThrowingStream<TerminalEventWire, Error> = try await workspace
                        .relay(for: managed.info.deviceId)
                        .stream(method: TerminalRpcMethod.subscribe, params: params.toDictionary())
                    managed.connecting = false
                    managed.error = nil
                    backoffNs = 500_000_000
                    for try await event in stream {
                        if Task.isCancelled || managed.closed { return }
                        self.apply(event, to: managed)
                        if managed.info.exited { return }
                    }
                    if managed.info.exited || managed.closed { return }
                } catch {
                    if Task.isCancelled || managed.closed { return }
                    managed.connecting = false
                    if case RelayError.rpc(let message) = error {
                        managed.error = message
                        return
                    }
                    managed.error = describeUserFacingError(error)
                }
                try? await Task.sleep(nanoseconds: backoffNs)
                backoffNs = min(backoffNs * 2, 5_000_000_000)
            }
        }
    }

    private func apply(_ event: TerminalEventWire, to managed: ManagedHostTerminal) {
        managed.info.lastSeq = max(managed.info.lastSeq, event.seq)
        switch event {
        case .data:
            if let bytes = event.decodedBytes {
                managed.screen.feed(bytes)
                managed.markRendered()
            }
        case .exit(_, let code, let signal):
            managed.info.exited = true
            managed.info.exitCode = code
            managed.info.signal = signal
            managed.connecting = false
            let sigSuffix = signal.map { " (\($0))" } ?? ""
            managed.screen.feed("\r\n\u{1B}[2m[Process exited with code \(code)\(sigSuffix)]\u{1B}[0m\r\n")
            managed.markRendered()
        }
    }

    func sendInput(_ text: String, to terminalId: String, model: AppModel) {
        sendBytes(Data(text.utf8), to: terminalId, model: model)
    }

    func sendBytes(_ data: Data, to terminalId: String, model: AppModel) {
        guard !data.isEmpty, let managed = terminal(id: terminalId), !managed.info.exited else { return }
        if managed.isDemo {
            handleDemoInput(data, managed: managed)
            return
        }
        guard let workspace = model.workspace else { return }
        let params = WriteTerminalParams(terminalId: terminalId, rawBytes: data)
        let deviceId = managed.info.deviceId
        Task {
            do {
                let _: TerminalOkReply = try await workspace.relay(for: deviceId)
                    .call(method: TerminalRpcMethod.write,
                          params: params.toDictionary(),
                          timeoutSeconds: 10,
                          retry: false)
            } catch {
                await MainActor.run { [weak managed] in
                    managed?.error = describeUserFacingError(error)
                }
            }
        }
    }

    func resize(terminalId: String, cols: Int, rows: Int, model: AppModel) {
        guard let managed = terminal(id: terminalId) else { return }
        let clampedCols = max(2, min(500, cols))
        let clampedRows = max(1, min(300, rows))
        guard clampedCols != managed.screen.cols || clampedRows != managed.screen.rows else { return }
        managed.screen.resize(cols: clampedCols, rows: clampedRows)
        managed.markRendered()
        guard !managed.isDemo, !managed.info.exited, let workspace = model.workspace else { return }
        let params = ResizeTerminalParams(
            terminalId: terminalId,
            cols: UInt16(clampedCols),
            rows: UInt16(clampedRows)
        )
        let deviceId = managed.info.deviceId
        Task {
            let _: TerminalOkReply? = try? await workspace.relay(for: deviceId)
                .call(method: TerminalRpcMethod.resize,
                      params: params.toDictionary(),
                      timeoutSeconds: 10,
                      retry: true)
        }
    }

    func closeTerminal(id terminalId: String, for chatId: String, model: AppModel) async {
        guard let managed = terminal(id: terminalId) else { return }
        managed.closed = true
        managed.streamTask?.cancel()
        managed.streamTask = nil

        if var list = terminalsByChat[chatId] {
            list.removeAll { $0.id == terminalId }
            if list.isEmpty {
                terminalsByChat.removeValue(forKey: chatId)
            } else {
                terminalsByChat[chatId] = list
            }
            if activeTerminalIdByChat[chatId] == terminalId {
                activeTerminalIdByChat[chatId] = list.first?.id
            }
        }

        guard !managed.isDemo, let workspace = model.workspace else { return }
        let params = CloseTerminalParams(terminalId: terminalId)
        let _: TerminalOkReply? = try? await workspace.relay(for: managed.info.deviceId)
            .call(method: TerminalRpcMethod.close,
                  params: params.toDictionary(),
                  timeoutSeconds: 10,
                  retry: true)
    }

    // MARK: Demo Shell

    private func seedDemoBanner(_ managed: ManagedHostTerminal, chat: Chat) {
        let cwd = managed.info.cwd
        let branch = chat.branch ?? "main"
        let banner = """
        \u{1B}[36m┌──────────────────────────────────────────────┐\u{1B}[0m\r
        \u{1B}[36m│\u{1B}[0m \u{1B}[1mHarness Host Shell\u{1B}[0m  \u{1B}[32m● live\u{1B}[0m                  \u{1B}[36m│\u{1B}[0m\r
        \u{1B}[36m│\u{1B}[0m \u{1B}[2mcwd:\u{1B}[0m \(cwd)\r
        \u{1B}[36m│\u{1B}[0m \u{1B}[2mgit:\u{1B}[0m \(branch)\r
        \u{1B}[36m└──────────────────────────────────────────────┘\u{1B}[0m\r
        Type \u{1B}[33mhelp\u{1B}[0m, \u{1B}[33mgit status\u{1B}[0m, \u{1B}[33mls\u{1B}[0m, or \u{1B}[33mcargo test\u{1B}[0m.\r\n
        """
        managed.screen.feed(banner)
        writeDemoPrompt(managed)
    }

    private func writeDemoPrompt(_ managed: ManagedHostTerminal) {
        let folder = (managed.info.cwd as NSString).lastPathComponent
        managed.screen.feed("\u{1B}[32mdev@host\u{1B}[0m \u{1B}[34m\(folder)\u{1B}[0m % ")
        managed.markRendered()
    }

    private func handleDemoInput(_ data: Data, managed: ManagedHostTerminal) {
        if let str = String(data: data, encoding: .utf8) {
            if str == "\u{1B}[A" {
                recallDemoHistory(step: -1, managed: managed)
                return
            }
            if str == "\u{1B}[B" {
                recallDemoHistory(step: 1, managed: managed)
                return
            }
            if str.hasPrefix("\u{1B}") { return }
        }
        for byte in data {
            switch byte {
            case 0x03: // ^C
                managed.demoLineBuffer = ""
                managed.demoHistoryIndex = nil
                managed.screen.feed("^C\r\n")
                writeDemoPrompt(managed)
            case 0x04: // ^D
                if managed.demoLineBuffer.isEmpty {
                    managed.info.exited = true
                    managed.info.exitCode = 0
                    managed.screen.feed("\r\n\u{1B}[2m[Process exited with code 0]\u{1B}[0m\r\n")
                    managed.markRendered()
                    return
                }
            case 0x0C: // ^L
                managed.screen.feed("\u{1B}[2J\u{1B}[H")
                writeDemoPrompt(managed)
                managed.screen.feed(managed.demoLineBuffer)
                managed.markRendered()
            case 0x09: // Tab
                let candidates = ["help", "git status", "ls", "pwd", "cargo test", "clear", "exit"]
                if let match = candidates.first(where: { $0.hasPrefix(managed.demoLineBuffer) && $0 != managed.demoLineBuffer }) {
                    let suffix = String(match.dropFirst(managed.demoLineBuffer.count))
                    managed.demoLineBuffer = match
                    managed.screen.feed(suffix)
                    managed.markRendered()
                }
            case 0x7F, 0x08: // DEL / BS
                if !managed.demoLineBuffer.isEmpty {
                    managed.demoLineBuffer.removeLast()
                    managed.screen.feed("\u{08} \u{08}")
                    managed.markRendered()
                }
            case 0x0D, 0x0A: // Enter
                let command = managed.demoLineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                managed.demoLineBuffer = ""
                managed.demoHistoryIndex = nil
                managed.screen.feed("\r\n")
                runDemoCommand(command, managed: managed)
                if !managed.info.exited {
                    writeDemoPrompt(managed)
                }
            default:
                if byte >= 0x20, byte < 0x7F {
                    let ch = String(Unicode.Scalar(byte))
                    managed.demoLineBuffer.append(ch)
                    managed.screen.feed(ch)
                    managed.markRendered()
                }
            }
        }
    }

    private func recallDemoHistory(step: Int, managed: ManagedHostTerminal) {
        guard !managed.demoHistory.isEmpty else { return }
        let nextIndex: Int
        if let cur = managed.demoHistoryIndex {
            nextIndex = max(0, min(managed.demoHistory.count, cur + step))
        } else {
            nextIndex = step < 0 ? managed.demoHistory.count - 1 : managed.demoHistory.count
        }
        for _ in managed.demoLineBuffer {
            managed.screen.feed("\u{08} \u{08}")
        }
        if nextIndex == managed.demoHistory.count {
            managed.demoHistoryIndex = nil
            managed.demoLineBuffer = ""
        } else {
            managed.demoHistoryIndex = nextIndex
            managed.demoLineBuffer = managed.demoHistory[nextIndex]
            managed.screen.feed(managed.demoLineBuffer)
        }
        managed.markRendered()
    }

    private func runDemoCommand(_ command: String, managed: ManagedHostTerminal) {
        guard !command.isEmpty else { return }
        managed.demoHistory.append(command)
        switch command {
        case "help":
            managed.screen.feed("Demo shell commands: \u{1B}[36mpwd\u{1B}[0m, \u{1B}[36mls\u{1B}[0m, \u{1B}[36mgit status\u{1B}[0m, \u{1B}[36mcargo test\u{1B}[0m, \u{1B}[36mclear\u{1B}[0m, \u{1B}[36mexit\u{1B}[0m\r\n")
        case "pwd":
            managed.screen.feed("\(managed.info.cwd)\r\n")
        case "ls":
            managed.screen.feed("\u{1B}[34mapps/\u{1B}[0m  \u{1B}[34mcrates/\u{1B}[0m  \u{1B}[34mdocs/\u{1B}[0m  Cargo.toml  README.md\r\n")
        case "git status":
            managed.screen.feed("On branch main\r\nnothing to commit, working tree clean\r\n")
        case "cargo test":
            managed.screen.feed("\u{1B}[32mrunning 12 tests\u{1B}[0m\r\ntest result: \u{1B}[32mok\u{1B}[0m. 12 passed; 0 failed\r\n")
        case "clear":
            managed.screen.feed("\u{1B}[2J\u{1B}[H")
        case "exit":
            managed.info.exited = true
            managed.info.exitCode = 0
            managed.screen.feed("\u{1B}[2m[Process exited with code 0]\u{1B}[0m\r\n")
        default:
            if command.hasPrefix("echo ") {
                managed.screen.feed("\(command.dropFirst(5))\r\n")
            } else {
                managed.screen.feed("zsh: command not found: \(command)\r\n")
            }
        }
    }
}

// MARK: - Terminal Key Bar

struct TerminalKeyBar: View {
    @Binding var ctrlActive: Bool
    let onSendBytes: (Data) -> Void
    var onDismissKeyboard: (() -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                keyButton("Esc") { onSendBytes(Data([0x1B])) }
                keyButton("Tab") { onSendBytes(Data([0x09])) }
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    ctrlActive.toggle()
                } label: {
                    Text("Ctrl")
                        .font(Theme.mono(12).weight(.semibold))
                        .foregroundStyle(ctrlActive ? Theme.onAccent : Theme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(ctrlActive ? Theme.accent : Theme.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                            .strokeBorder(ctrlActive ? Theme.accent : Theme.border, lineWidth: 1))
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityIdentifier("term-key-ctrl")

                keyButton("↑") { onSendBytes(Data([0x1B, 0x5B, 0x41])) }
                keyButton("↓") { onSendBytes(Data([0x1B, 0x5B, 0x42])) }
                keyButton("←") { onSendBytes(Data([0x1B, 0x5B, 0x44])) }
                keyButton("→") { onSendBytes(Data([0x1B, 0x5B, 0x43])) }
                keyButton("^C") { onSendBytes(Data([0x03])) }
                keyButton("^D") { onSendBytes(Data([0x04])) }
                keyButton("|") { onSendBytes(Data("|".utf8)) }
                keyButton("/") { onSendBytes(Data("/".utf8)) }
                keyButton("~") { onSendBytes(Data("~".utf8)) }

                if let onDismissKeyboard {
                    Button(action: onDismissKeyboard) {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 34, height: 30)
                            .background(Theme.surfaceRaised,
                                        in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                                .strokeBorder(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityLabel("Hide keyboard")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .accessibilityIdentifier("terminal-key-bar")
    }

    private func keyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(Theme.mono(12).weight(.medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 9)
                .frame(minWidth: 32)
                .frame(height: 30)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(PressScaleButtonStyle())
    }
}

// MARK: - CoreGraphics Terminal Canvas

private struct TerminalMetrics {
    let fontSize: CGFloat
    let font: UIFont
    let boldFont: UIFont
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let baselineOffset: CGFloat

    init(fontSize: CGFloat = 12.5) {
        self.fontSize = fontSize
        let base = Theme.monoUI(fontSize)
        self.font = base
        let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold)
        self.boldFont = descriptor.map { UIFont(descriptor: $0, size: fontSize) }
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let sample = ("W" as NSString).size(withAttributes: [.font: base])
        self.cellWidth = max(6, ceil(sample.width))
        self.cellHeight = max(14, ceil(base.lineHeight * 1.15))
        self.baselineOffset = (cellHeight - base.lineHeight) * 0.5
    }
}

private final class TerminalCanvasUIView: UIView {
    var screen: TerminalScreenBuffer?
    var metrics = TerminalMetrics()
    var isDark = true
    var showCursor = true
    var onGridSizeChange: ((Int, Int) -> Void)?
    var onTap: (() -> Void)?

    private var scrollOffsetRows: Int = 0
    private var panAccumulatorY: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleTap() {
        onTap?()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let screen else { return }
        let dy = gesture.translation(in: self).y
        gesture.setTranslation(.zero, in: self)
        panAccumulatorY += dy
        let rowStep = Int(panAccumulatorY / metrics.cellHeight)
        if rowStep != 0 {
            panAccumulatorY -= CGFloat(rowStep) * metrics.cellHeight
            let maxOffset = screen.isAlternateScreen ? 0 : screen.scrollback.count
            scrollOffsetRows = max(0, min(maxOffset, scrollOffsetRows + rowStep))
            setNeedsDisplay()
        }
    }

    func scrollToBottomIfNeeded() {
        if scrollOffsetRows != 0 {
            scrollOffsetRows = 0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cols = max(20, Int(floor(max(1, bounds.width - 12) / metrics.cellWidth)))
        let rows = max(6, Int(floor(max(1, bounds.height - 8) / metrics.cellHeight)))
        onGridSizeChange?(cols, rows)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let bgColor = UIColor(Theme.bg)
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(bounds)

        guard let screen else { return }
        let padX: CGFloat = 6
        let padY: CGFloat = 4
        let cw = metrics.cellWidth
        let ch = metrics.cellHeight

        let scrollbackCount = screen.isAlternateScreen ? 0 : screen.scrollback.count
        let clampedOffset = min(scrollOffsetRows, scrollbackCount)
        let totalVisibleStart = scrollbackCount - clampedOffset

        for r in 0..<screen.rows {
            let lineIndex = totalVisibleStart + r
            let rowCells: [TerminalCell]
            if lineIndex < scrollbackCount {
                rowCells = screen.scrollback[lineIndex]
            } else {
                let gridRow = lineIndex - scrollbackCount
                guard gridRow >= 0, gridRow < screen.rows else { continue }
                rowCells = screen.grid[gridRow]
            }
            let y = padY + CGFloat(r) * ch

            for c in 0..<min(screen.cols, rowCells.count) {
                let cell = rowCells[c]
                if cell.width == 0 { continue }
                let x = padX + CGFloat(c) * cw
                let cellRect = CGRect(x: x, y: y, width: cw, height: ch)
                let attrs = cell.attributes
                var fg = attrs.foreground.resolvedUIColor(isDark: isDark, isForeground: true)
                var bg = attrs.background.resolvedUIColor(isDark: isDark, isForeground: false)
                if attrs.inverse { swap(&fg, &bg) }
                if attrs.dim { fg = fg.withAlphaComponent(0.6) }

                if attrs.inverse || attrs.background != .defaultBackground {
                    ctx.setFillColor(bg.cgColor)
                    ctx.fill(cellRect)
                }

                let isCursor = showCursor && clampedOffset == 0 && screen.cursorVisible
                    && r == screen.cursorRow && c == screen.cursorCol
                if isCursor {
                    ctx.setFillColor(UIColor(Theme.accent).withAlphaComponent(0.85).cgColor)
                    ctx.fill(cellRect)
                    fg = UIColor(Theme.onAccent)
                }

                if cell.scalar == " " && !attrs.underline { continue }

                switch TerminalGlyphKind.classify(cell.scalar) {
                case .blockElement:
                    drawBlockElement(cell.scalar, in: cellRect, color: fg, ctx: ctx)
                case .boxDrawing:
                    if !drawBoxDrawing(cell.scalar, in: cellRect, color: fg, ctx: ctx) {
                        drawTextScalar(cell.scalar, in: cellRect, color: fg, attrs: attrs)
                    }
                case .text:
                    if cell.scalar != " " {
                        drawTextScalar(cell.scalar, in: cellRect, color: fg, attrs: attrs)
                    }
                }

                if attrs.underline {
                    ctx.setFillColor(fg.cgColor)
                    ctx.fill(CGRect(x: x, y: y + ch - 1.5, width: cw, height: 1))
                }
            }
        }
    }

    private func drawTextScalar(_ scalar: Unicode.Scalar, in rect: CGRect, color: UIColor, attrs: TerminalAttributes) {
        let font = attrs.bold ? metrics.boldFont : metrics.font
        let str = String(scalar) as NSString
        str.draw(at: CGPoint(x: rect.minX, y: rect.minY + metrics.baselineOffset),
                 withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawBlockElement(_ scalar: Unicode.Scalar, in rect: CGRect, color: UIColor, ctx: CGContext) {
        let v = scalar.value
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        ctx.setFillColor(color.cgColor)

        switch v {
        case 0x2580: ctx.fill(CGRect(x: x, y: y, width: w, height: h * 0.5)) // ▀
        case 0x2581...0x2588: // ▁..█ lower 1/8..8/8
            let frac = CGFloat(v - 0x2580) / 8.0
            ctx.fill(CGRect(x: x, y: y + h * (1 - frac), width: w, height: h * frac))
        case 0x2589...0x258F: // ▉..▏ left 7/8..1/8
            let frac = CGFloat(0x2590 - v) / 8.0
            ctx.fill(CGRect(x: x, y: y, width: w * frac, height: h))
        case 0x2590: ctx.fill(CGRect(x: x + w * 0.5, y: y, width: w * 0.5, height: h)) // ▐
        case 0x2591: // ░
            ctx.setFillColor(color.withAlphaComponent(0.25).cgColor)
            ctx.fill(rect)
        case 0x2592: // ▒
            ctx.setFillColor(color.withAlphaComponent(0.50).cgColor)
            ctx.fill(rect)
        case 0x2593: // ▓
            ctx.setFillColor(color.withAlphaComponent(0.75).cgColor)
            ctx.fill(rect)
        case 0x2594: ctx.fill(CGRect(x: x, y: y, width: w, height: h * 0.125)) // ▔
        case 0x2595: ctx.fill(CGRect(x: x + w * 0.875, y: y, width: w * 0.125, height: h)) // ▕
        case 0x2596...0x259F:
            let bits = quadrantMask(v)
            let hw = w * 0.5, hh = h * 0.5
            if bits & 1 != 0 { ctx.fill(CGRect(x: x, y: y, width: hw, height: hh)) }
            if bits & 2 != 0 { ctx.fill(CGRect(x: x + hw, y: y, width: hw, height: hh)) }
            if bits & 4 != 0 { ctx.fill(CGRect(x: x, y: y + hh, width: hw, height: hh)) }
            if bits & 8 != 0 { ctx.fill(CGRect(x: x + hw, y: y + hh, width: hw, height: hh)) }
        default:
            ctx.fill(rect)
        }
    }

    private func quadrantMask(_ v: UInt32) -> Int {
        switch v {
        case 0x2596: return 0b0100
        case 0x2597: return 0b1000
        case 0x2598: return 0b0001
        case 0x2599: return 0b1101
        case 0x259A: return 0b1001
        case 0x259B: return 0b0111
        case 0x259C: return 0b1011
        case 0x259D: return 0b0010
        case 0x259E: return 0b0110
        case 0x259F: return 0b1110
        default: return 0b1111
        }
    }

    private func drawBoxDrawing(_ scalar: Unicode.Scalar, in rect: CGRect, color: UIColor, ctx: CGContext) -> Bool {
        let midX = rect.midX, midY = rect.midY
        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY
        let thin: CGFloat = 1.25
        let thick: CGFloat = 2.4

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineCap(.butt)

        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, width: CGFloat = thin) {
            ctx.setLineWidth(width)
            ctx.move(to: CGPoint(x: x1, y: y1))
            ctx.addLine(to: CGPoint(x: x2, y: y2))
            ctx.strokePath()
        }

        switch scalar.value {
        case 0x2500: line(minX, midY, maxX, midY)                                   // ─
        case 0x2501: line(minX, midY, maxX, midY, width: thick)                     // ━
        case 0x2502: line(midX, minY, midX, maxY)                                   // │
        case 0x2503: line(midX, minY, midX, maxY, width: thick)                     // ┃
        case 0x250C: line(midX, midY, maxX, midY); line(midX, midY, midX, maxY)     // ┌
        case 0x2510: line(minX, midY, midX, midY); line(midX, midY, midX, maxY)     // ┐
        case 0x2514: line(midX, minY, midX, midY); line(midX, midY, maxX, midY)     // └
        case 0x2518: line(midX, minY, midX, midY); line(minX, midY, midX, midY)     // ┘
        case 0x251C: line(midX, minY, midX, maxY); line(midX, midY, maxX, midY)     // ├
        case 0x2524: line(midX, minY, midX, maxY); line(minX, midY, midX, midY)     // ┤
        case 0x252C: line(minX, midY, maxX, midY); line(midX, midY, midX, maxY)     // ┬
        case 0x2534: line(minX, midY, maxX, midY); line(midX, minY, midX, midY)     // ┴
        case 0x253C: line(minX, midY, maxX, midY); line(midX, minY, midX, maxY)     // ┼
        case 0x2550:                                                                // ═
            line(minX, midY - 1.5, maxX, midY - 1.5)
            line(minX, midY + 1.5, maxX, midY + 1.5)
        case 0x2551:                                                                // ║
            line(midX - 1.5, minY, midX - 1.5, maxY)
            line(midX + 1.5, minY, midX + 1.5, maxY)
        case 0x256D:                                                                // ╭
            ctx.setLineWidth(thin)
            ctx.move(to: CGPoint(x: maxX, y: midY))
            ctx.addQuadCurve(to: CGPoint(x: midX, y: maxY), control: CGPoint(x: midX, y: midY))
            ctx.strokePath()
        case 0x256E:                                                                // ╮
            ctx.setLineWidth(thin)
            ctx.move(to: CGPoint(x: minX, y: midY))
            ctx.addQuadCurve(to: CGPoint(x: midX, y: maxY), control: CGPoint(x: midX, y: midY))
            ctx.strokePath()
        case 0x256F:                                                                // ╯
            ctx.setLineWidth(thin)
            ctx.move(to: CGPoint(x: minX, y: midY))
            ctx.addQuadCurve(to: CGPoint(x: midX, y: minY), control: CGPoint(x: midX, y: midY))
            ctx.strokePath()
        case 0x2570:                                                                // ╰
            ctx.setLineWidth(thin)
            ctx.move(to: CGPoint(x: maxX, y: midY))
            ctx.addQuadCurve(to: CGPoint(x: midX, y: minY), control: CGPoint(x: midX, y: midY))
            ctx.strokePath()
        default:
            return false
        }
        return true
    }
}

private final class TerminalKeyInputUIView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }
}

private struct TerminalSurfaceRepresentable: UIViewRepresentable {
    let managed: ManagedHostTerminal
    let renderTick: UInt64
    let isDark: Bool
    @Binding var focusToken: Int
    @Binding var blurToken: Int
    let onGridSizeChange: (Int, Int) -> Void
    let onText: (String) -> Void
    let onDeleteBackward: () -> Void

    final class Coordinator {
        var lastFocusToken = 0
        var lastBlurToken = 0
        weak var keyInput: TerminalKeyInputUIView?
        weak var canvas: TerminalCanvasUIView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let keyInput = TerminalKeyInputUIView(frame: .zero)
        keyInput.isHidden = true
        keyInput.onText = onText
        keyInput.onDeleteBackward = onDeleteBackward
        container.addSubview(keyInput)

        let canvas = TerminalCanvasUIView(frame: container.bounds)
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.onGridSizeChange = onGridSizeChange
        canvas.onTap = { [weak keyInput] in
            keyInput?.becomeFirstResponder()
        }
        container.addSubview(canvas)

        context.coordinator.keyInput = keyInput
        context.coordinator.canvas = canvas
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.keyInput?.onText = onText
        coordinator.keyInput?.onDeleteBackward = onDeleteBackward
        if let canvas = coordinator.canvas {
            canvas.screen = managed.screen
            canvas.isDark = isDark
            canvas.showCursor = !managed.info.exited
            canvas.onGridSizeChange = onGridSizeChange
            canvas.setNeedsDisplay()
        }
        if focusToken != coordinator.lastFocusToken {
            coordinator.lastFocusToken = focusToken
            coordinator.keyInput?.becomeFirstResponder()
        }
        if blurToken != coordinator.lastBlurToken {
            coordinator.lastBlurToken = blurToken
            coordinator.keyInput?.resignFirstResponder()
        }
    }
}

// MARK: - HostTerminalView

struct HostTerminalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    let store: HostTerminalStore
    let terminalId: String
    let chat: Chat

    @State private var ctrlActive = false
    @State private var focusToken = 0
    @State private var blurToken = 0
    @State private var copied = false

    var body: some View {
        if let managed = store.terminal(id: terminalId) {
            VStack(spacing: 0) {
                statusBar(managed)
                TerminalSurfaceRepresentable(
                    managed: managed,
                    renderTick: managed.renderTick,
                    isDark: colorScheme == .dark,
                    focusToken: $focusToken,
                    blurToken: $blurToken,
                    onGridSizeChange: { cols, rows in
                        store.resize(terminalId: terminalId, cols: cols, rows: rows, model: model)
                    },
                    onText: { text in
                        let encoded = TerminalInputEncoder.encode(text: text, ctrl: ctrlActive)
                        if encoded.consumedCtrl { ctrlActive = false }
                        store.sendBytes(encoded.data, to: terminalId, model: model)
                    },
                    onDeleteBackward: {
                        ctrlActive = false
                        store.sendBytes(Data([0x7F]), to: terminalId, model: model)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                .accessibilityIdentifier("host-terminal-surface")

                TerminalKeyBar(
                    ctrlActive: $ctrlActive,
                    onSendBytes: { bytes in
                        store.sendBytes(bytes, to: terminalId, model: model)
                    },
                    onDismissKeyboard: {
                        blurToken += 1
                    }
                )
            }
        } else {
            ContentUnavailableView(
                "Terminal Closed",
                systemImage: "terminal",
                description: Text("This terminal session is no longer active.")
            )
        }
    }

    private func statusBar(_ managed: ManagedHostTerminal) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(managed.info.exited ? Theme.textFaint : Theme.statusCompleted)
                .frame(width: 7, height: 7)
            Text(managed.info.shell)
                .font(Theme.mono(12).weight(.medium))
                .foregroundStyle(Theme.text)
            Text(managed.info.cwd)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if managed.connecting {
                ProgressView()
                    .controlSize(.mini)
            } else if let error = managed.error {
                Button("Retry") {
                    store.reconnect(terminalId: terminalId, model: model)
                }
                .font(Theme.sans(11, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .help(error)
            } else if managed.info.exited {
                Text("Exited \(managed.info.exitCode ?? 0)")
                    .font(Theme.sans(11, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
            }
            Button {
                UIPasteboard.general.string = managed.screen.plainText(includeScrollback: true)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy terminal output")
            Button {
                focusToken += 1
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Focus keyboard")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

