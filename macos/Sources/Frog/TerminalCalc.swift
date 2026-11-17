import AppKit

@MainActor
extension LauncherModel {
    var isCalcActive: Bool { buffer == .calc && inputKind == .calc }

    func openCalc() {
        guard prompt == nil, !busy else { return }
        bufferOrigin = nil
        calcHistoryFocused = false
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
        let next = min(max(0, (calcHistoryIndex ?? 0) + direction), calcHistory.count - 1)
        selectCalcEntry(at: next)
    }

    func selectCalcEntry(at index: Int) {
        guard prompt == nil, !busy, calcHistory.indices.contains(index) else { return }
        calcHistoryFocused = true
        inputKind = nil
        calcHistoryIndex = index
        setCalcFeedback(nil)
        let capacity = LauncherModel.calcVisibleRows
        if index < bufferOffset { bufferOffset = index }
        else if index >= bufferOffset + capacity { bufferOffset = index - capacity + 1 }
        bufferOffset = max(0, min(bufferOffset, max(0, calcHistory.count - capacity)))
    }

    func focusCalcInput() {
        calcHistoryFocused = false
        setInput(.calc, text: calcExpression)
    }

    func loadCalcHistorySelection() {
        guard let index = calcHistoryIndex, calcHistory.indices.contains(index) else { return }
        calcExpression = calcHistory[index].expression
        calcError = nil
        focusCalcInput()
    }

    func copyCalcResult() {
        let text: String?
        if calcHistoryFocused, let index = calcHistoryIndex, calcHistory.indices.contains(index) {
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
        calcHistoryFocused = false
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
        guard buffer == .calc, !calcHistoryFocused, inputKind == nil, prompt == nil, !busy else { return }
        setInput(.calc, text: calcExpression)
    }

    /// 键盘事件在输入框之前拦截；只消费计算器自己的按键，其余字符交给字段编辑器。
    func handleCalcKey(_ event: NSEvent, characters: String) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            if calcHistoryFocused { focusCalcInput() }
            else if !calcHistory.isEmpty { selectCalcEntry(at: calcHistoryIndex ?? 0) }
            return true
        }
        if characters == ":", modifiers.isEmpty || modifiers == .shift { startCommand(); return true }
        if calcHistoryFocused {
            guard modifiers.isEmpty else { return false }
            switch event.keyCode {
            case 36, 76: loadCalcHistorySelection()
            case 125: browseCalcHistory(1)
            case 126: browseCalcHistory(-1)
            case 121: browseCalcHistory(Self.calcVisibleRows)
            case 116: browseCalcHistory(-Self.calcVisibleRows)
            default: return false
            }
            return true
        }
        if modifiers.isEmpty, [36, 76].contains(event.keyCode) { submitCalc(); return true }
        // 字符过滤在文本变更后统一完成；不截走原生选区和光标操作。
        return false
    }
}
