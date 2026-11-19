import Foundation

// 原生绘制与命令模型共用的值类型；界面只消费真实状态，不包含原型场景模拟。
enum TerminalBuffer: String { case settings, help, log, job, calc, commands }
enum TerminalInputKind { case command, search, prompt, calc }
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
    var choicesFocused: Bool = false
    var acceptsText: Bool = true
    var keyboardHint: String {
        choicesFocused ? "↑↓ 选择 · Enter 采纳 · Esc 返回输入" : hint
    }
    var commandTitle: String {
        switch command {
        case "add": return "添加"
        case "edit": return "编辑"
        case "rename": return "重命名"
        case "mkdir": return "新建文件夹"
        case "move": return "移动"
        case "delete": return "删除"
        case "hotkey": return "快捷键"
        case "backup": return "导出备份"
        case "restore": return "恢复备份"
        case "cd": return "数据目录"
        case "commands-edit": return "命令"
        case "commands-delete": return "删除"
        default: return command
        }
    }
    var fieldTitle: String {
        switch field {
        case "url": return "网址"
        case "title": return "标题"
        case "location", "to": return "位置"
        case "folder": return "新文件夹"
        case "name": return command == "rename" ? "新名称" : "名称"
        case "path": return "路径"
        case "file": return "文件"
        case "confirm": return "确认"
        case "press keys": return "按下组合键"
        default: return field
        }
    }
    var label: String {
        "\(commandTitle)\(total > 1 ? " \(step + 1)/\(total)" : "") › \(fieldTitle)"
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

struct TerminalCalcEntry: Identifiable, Equatable {
    let id: Int
    var time: String
    var expression: String
    var value: String
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
