import Foundation

// 原生绘制与命令模型共用的值类型；界面只消费真实状态，不包含原型场景模拟。
enum TerminalBuffer: String { case settings, help, log, job }
enum TerminalInputKind { case command, search, prompt }
enum TerminalItemKind { case bookmark, folder }
enum TerminalLevel { case normal, muted, info, success, warning, error, command }
enum TerminalJobStatus { case running, success, failure }

struct TerminalItem: Identifiable, Equatable {
    let id: String
    let kind: TerminalItemKind
    var title: String
    var detail: String = ""
    var url: String? = nil
    var groupID: String? = nil
    var groupName: String? = nil
    var depth: Int = 0
    var expanded: Bool = false
}

struct TerminalChoice: Identifiable, Equatable {
    let id: String
    var label: String
    var detail: String = ""
}

struct TerminalPrompt: Equatable {
    var command: String
    var step: Int = 0
    var total: Int = 0
    var field: String
    var hint: String
    var error: String? = nil
    var context: String? = nil
    var choices: [TerminalChoice] = []
    var selectedChoice: Int = 0
    var acceptsText: Bool = true
    var label: String {
        "\(command)\(total > 0 ? " \(step + 1)/\(total)" : "") › \(field)"
    }
}

struct TerminalLogEntry: Identifiable, Equatable {
    let id: Int
    var time: String
    var text: String
    var level: TerminalLevel = .normal
}

struct TerminalJob: Equatable {
    var title: String
    var status: TerminalJobStatus
    var lines: [TerminalLogEntry]
}

struct TerminalSettingRow: Equatable {
    enum Kind { case section, value, note, action, blank }
    var kind: Kind
    var key: String = ""
    var value: String = ""
    var command: String = ""
    var level: TerminalLevel = .normal
}

struct TerminalCommand: Identifiable, Equatable {
    var name: String
    var summary: String
    var usage: String
    var detail: String = ""
    var id: String { name }
}
