import XCTest
@testable import Frog

final class TerminalCalculatorTests: XCTestCase {
    func testPrecedenceParenthesesAndUnaryOperators() throws {
        XCTAssertEqual(try TerminalCalculator.evaluate("2+3*4"), 14)
        XCTAssertEqual(try TerminalCalculator.evaluate("(2+3)*4"), 20)
        XCTAssertEqual(try TerminalCalculator.evaluate("12 * (8 - 3)"), 60)
        XCTAssertEqual(try TerminalCalculator.evaluate("8/2/2"), 2)
        XCTAssertEqual(try TerminalCalculator.evaluate("-3+5"), 2)
        XCTAssertEqual(try TerminalCalculator.evaluate("2--3"), 5)
        XCTAssertEqual(try TerminalCalculator.evaluate("0.1+0.2"), 0.30000000000000004, accuracy: 1e-12)
    }

    func testFullWidthParenthesesAreNormalizedAndFiltered() throws {
        XCTAssertEqual(TerminalCalculator.normalize("（1+2）*3"), "(1+2)*3")
        XCTAssertEqual(TerminalCalculator.filtered("（1+2）abc * 3"), "(1+2) * 3")
        XCTAssertEqual(TerminalCalculator.filtered("1+2c"), "1+2")
        XCTAssertEqual(TerminalCalculator.filtered("1e-6"), "1e-6")
        XCTAssertEqual(try TerminalCalculator.evaluate("（1+2）*3"), 9)
    }

    func testExponentResultsRoundTripThroughTheParser() throws {
        XCTAssertEqual(TerminalCalculator.format(1e-7), "1e-7")
        XCTAssertEqual(try TerminalCalculator.evaluate(TerminalCalculator.format(1e-7)), 1e-7, accuracy: 1e-20)
        XCTAssertEqual(TerminalCalculator.format(1e21), "1e+21")
        XCTAssertEqual(try TerminalCalculator.evaluate(TerminalCalculator.format(1e21)), 1e21, accuracy: 1e14)
        XCTAssertEqual(try TerminalCalculator.evaluate("2e+3"), 2000)
    }

    func testInputLengthIsCapped() throws {
        let long = String(repeating: "(", count: 300)
        XCTAssertEqual(TerminalCalculator.filtered(long).count, TerminalCalculator.maxLength)
        XCTAssertThrowsError(try TerminalCalculator.evaluate(long)) { error in
            XCTAssertEqual(error.localizedDescription, "算式过长")
        }
    }

    func testFormattingUsesTwelveSignificantDigits() {
        XCTAssertEqual(TerminalCalculator.format(0.1 + 0.2), "0.3")
        XCTAssertEqual(TerminalCalculator.format(60), "60")
        XCTAssertEqual(TerminalCalculator.format(-0.0), "0")
        XCTAssertEqual(TerminalCalculator.format(1.0 / 3.0), "0.333333333333")
    }

    func testErrorsCarryActionableMessages() {
        XCTAssertThrowsError(try TerminalCalculator.evaluate("")) { error in
            XCTAssertEqual(error.localizedDescription, "请输入算式")
        }
        XCTAssertThrowsError(try TerminalCalculator.evaluate("   ")) { error in
            XCTAssertEqual(error.localizedDescription, "请输入算式")
        }
        XCTAssertThrowsError(try TerminalCalculator.evaluate("1/0")) { error in
            XCTAssertEqual(error.localizedDescription, "不能除以 0")
        }
        XCTAssertThrowsError(try TerminalCalculator.evaluate("(1+2")) { error in
            XCTAssertEqual(error.localizedDescription, "缺少右括号")
        }
        XCTAssertThrowsError(try TerminalCalculator.evaluate("1+2)")) { error in
            XCTAssertEqual(error.localizedDescription, "多余的右括号")
        }
        XCTAssertThrowsError(try TerminalCalculator.evaluate("1+*2")) { error in
            XCTAssertEqual(error.localizedDescription, "算式不完整")
        }
        XCTAssertThrowsError(try TerminalCalculator.evaluate("1+a")) { error in
            XCTAssertEqual(error.localizedDescription, "无法识别的字符 “a”")
        }
    }
}
