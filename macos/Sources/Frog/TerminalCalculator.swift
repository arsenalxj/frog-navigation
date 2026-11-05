import Foundation

/// 计算器算式求值：仅支持 + - * /、小括号、小数与空格，不使用 NSExpression。
enum TerminalCalculator {
    static let maxLength = 256

    struct CalculateError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// 输入法打出的中文括号先归一化为英文括号。
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
    }

    /// 计算器输入只保留有效字符；用于粘贴和输入法提交后的兜底。
    static func filtered(_ text: String) -> String {
        let allowed = Set("0123456789+-*/().eE")
        let normalized = normalize(text)
        var result = ""
        result.reserveCapacity(min(normalized.count, maxLength))
        for character in normalized {
            guard allowed.contains(character) || character.isWhitespace else { continue }
            result.append(character)
            if result.count >= maxLength { break }
        }
        return result
    }

    /// 12 位有效数字，消除 0.1 + 0.2 一类浮点尾差。
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "无法计算" }
        if value == 0 { return "0" }
        var text = String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
        text = text.replacingOccurrences(of: "E", with: "e")
        text = text.replacingOccurrences(of: "e+0", with: "e+")
            .replacingOccurrences(of: "e-0", with: "e-")
        return text
    }

    static func evaluate(_ source: String) throws -> Double {
        let normalized = normalize(source)
        guard normalized.count <= maxLength else { throw CalculateError(message: "算式过长") }
        var parser = Parser(text: normalized)
        return try parser.run()
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        let text: String

        init(text: String) {
            self.text = text
            self.characters = Array(text)
        }

        mutating func run() throws -> Double {
            guard characters.contains(where: { !$0.isWhitespace }) else {
                throw CalculateError(message: "请输入算式")
            }
            let value = try expression()
            skipWhitespace()
            if index < characters.count {
                if characters[index] == ")" { throw CalculateError(message: "多余的右括号") }
                throw CalculateError(message: "无法识别的字符 “\(characters[index])”")
            }
            guard value.isFinite else { throw CalculateError(message: "结果超出可计算范围") }
            return value
        }

        mutating func expression() throws -> Double {
            var value = try term()
            while true {
                skipWhitespace()
                guard index < characters.count, ["+", "-"].contains(characters[index]) else { return value }
                let op = characters[index]
                index += 1
                let right = try term()
                value = op == "+" ? value + right : value - right
            }
        }

        mutating func term() throws -> Double {
            var value = try unary()
            while true {
                skipWhitespace()
                guard index < characters.count, ["*", "/"].contains(characters[index]) else { return value }
                let op = characters[index]
                index += 1
                let right = try unary()
                if op == "/" && right == 0 { throw CalculateError(message: "不能除以 0") }
                value = op == "*" ? value * right : value / right
            }
        }

        mutating func unary() throws -> Double {
            skipWhitespace()
            if index < characters.count, characters[index] == "+" {
                index += 1
                return try unary()
            }
            if index < characters.count, characters[index] == "-" {
                index += 1
                return -(try unary())
            }
            return try primary()
        }

        mutating func primary() throws -> Double {
            skipWhitespace()
            if index < characters.count, characters[index] == "(" {
                index += 1
                let value = try expression()
                skipWhitespace()
                guard index < characters.count, characters[index] == ")" else {
                    throw CalculateError(message: "缺少右括号")
                }
                index += 1
                return value
            }
            let start = index
            var hasDot = false
            while index < characters.count {
                let character = characters[index]
                if character.isNumber && character.isASCII {
                    index += 1
                } else if character == ".", !hasDot {
                    hasDot = true
                    index += 1
                } else {
                    break
                }
            }
            if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                    index += 1
                }
                let exponentStart = index
                while index < characters.count, characters[index].isNumber, characters[index].isASCII {
                    index += 1
                }
                guard index > exponentStart else { throw CalculateError(message: "算式不完整") }
            }
            guard index > start else {
                if index < characters.count {
                    let character = characters[index]
                    if character == ")" { throw CalculateError(message: "多余的右括号") }
                    if "+-*/".contains(character) { throw CalculateError(message: "算式不完整") }
                    throw CalculateError(message: "无法识别的字符 “\(character)”")
                }
                throw CalculateError(message: "算式不完整")
            }
            let literal = String(characters[start..<index])
            guard literal != ".", let value = Double(literal) else {
                throw CalculateError(message: "算式不完整")
            }
            return value
        }

        mutating func skipWhitespace() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }
    }
}
