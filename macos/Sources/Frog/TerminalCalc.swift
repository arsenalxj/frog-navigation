import AppKit

@MainActor
extension LauncherModel {
    var isCalcActive: Bool { buffer == .calc && inputKind == .calc }

    func openCalc() {
        guard prompt == nil, !busy else { return }
        buffer = .calc
        bufferOffset = 0
        calcHistoryIndex = nil
        calcError = nil
        setCalcFeedback(nil)
        setInput(.calc, text: calcExpression)
    }

    func submitCalc() {
        let expression = calcExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else {
            calcError = "请输入算式"
            return
        }
        do {
            let value = try TerminalCalculator.evaluate(expression)
            let text = TerminalCalculator.format(value)
            calcExpression = expression
            calcError = nil
            calcHistoryIndex = nil
            calcSequence &+= 1
            let entry = TerminalCalcEntry(id: calcSequence, time: clockFormatter.string(from: Date()),
                                          expression: expression, value: text)
            calcHistory.removeAll { $0.expression == expression }
            calcHistory.insert(entry, at: 0)
            if calcHistory.count > 50 { calcHistory.removeLast(calcHistory.count - 50) }
            bufferOffset = 0
            setInput(.calc, text: expression)
            setCalcFeedback(nil)
        } catch {
            calcError = error.localizedDescription
        }
    }

    func browseCalcHistory(_ direction: Int) {
        guard !calcHistory.isEmpty else { return }
        let next = calcHistoryIndex.map { $0 + direction } ?? 0
        guard calcHistory.indices.contains(next) else { return }
        selectCalcEntry(at: next)
    }

    func selectCalcEntry(at index: Int) {
        guard calcHistory.indices.contains(index) else { return }
        calcHistoryIndex = index
        calcExpression = calcHistory[index].expression
        calcError = nil
        setInput(.calc, text: calcExpression)
        setCalcFeedback(nil)
        let capacity = LauncherModel.calcVisibleRows
        if index < bufferOffset { bufferOffset = index }
        else if index >= bufferOffset + capacity { bufferOffset = index - capacity + 1 }
        bufferOffset = max(0, min(bufferOffset, max(0, calcHistory.count - capacity)))
    }

    func copyCalcResult() {
        let text: String?
        if let index = calcHistoryIndex, calcHistory.indices.contains(index) {
            text = calcHistory[index].value
        } else if let value = try? TerminalCalculator.evaluate(calcExpression) {
            text = TerminalCalculator.format(value)
        } else {
            text = nil
        }
        guard let text else {
            setCalcFeedback("✗ 没有可复制的结果", .error)
            return
        }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            setCalcFeedback("✓ 已复制 \(text)", .success)
        } else {
            setCalcFeedback("✗ 复制失败", .error)
        }
    }

    func clearCalc() {
        calcExpression = ""
        calcHistory = []
        calcHistoryIndex = nil
        calcError = nil
        bufferOffset = 0
        setCalcFeedback(nil)
        if buffer == .calc { setInput(.calc, text: "") }
    }

    func setCalcFeedback(_ text: String?, _ level: TerminalLevel = .success) {
        calcFeedbackTask?.cancel()
        calcFeedbackTask = nil
        calcFeedback = text
        calcFeedbackLevel = level
        guard text != nil else { return }
        calcFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.calcFeedback = nil
            self.calcFeedbackTask = nil
        }
    }

    func restoreCalcInputIfNeeded() {
        guard buffer == .calc, inputKind == nil, prompt == nil, !busy else { return }
        setInput(.calc, text: calcExpression)
    }

    /// 键盘事件在输入框之前拦截；只消费计算器自己的按键，其余字符交给字段编辑器。
    func handleCalcKey(_ event: NSEvent, characters: String) -> Bool {
        switch event.keyCode {
        case 36, 76: submitCalc(); return true
        case 125: browseCalcHistory(1); return true
        case 126: browseCalcHistory(-1); return true
        case 48: return true
        case 51, 117, 123, 124, 115, 119: return false
        default: break
        }
        if characters == "=" { submitCalc(); return true }
        if characters == ":" { startCommand(); return true }
        if characters.lowercased() == "c" { copyCalcResult(); return true }
        if characters.count == 1, let character = characters.first {
            let allowed = Set("0123456789+-*/().eE（）")
            return !(allowed.contains(character) || character.isWhitespace)
        }
        return false
    }
}
