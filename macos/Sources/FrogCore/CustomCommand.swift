import Foundation

public enum CustomCommandKind: String, Codable, CaseIterable, Sendable {
    case terminal, program, url

    public var label: String {
        switch self {
        case .terminal: "终端命令"
        case .program: "程序 / 脚本"
        case .url: "网址"
        }
    }
}

public enum CustomCommandTerminal: String, Codable, CaseIterable, Sendable {
    case terminal, iTerm2, ghostty, none

    public var label: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm2: "iTerm2"
        case .ghostty: "Ghostty"
        case .none: "不使用终端"
        }
    }
}

public enum CustomCommandError: Error, LocalizedError, Equatable {
    case invalidData(String)
    case unavailable(String)
    case externalChange

    public var errorDescription: String? {
        switch self {
        case .invalidData(let message), .unavailable(let message): message
        case .externalChange: "自定义命令文件已被外部修改，未覆盖原文件。请重新读取后再保存。"
        }
    }
}

public struct CustomCommand: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var title: String
    public var type: CustomCommandKind
    public var directory: String
    public var target: String
    public var arguments: String
    public var terminal: CustomCommandTerminal
    public var id: String { name }

    public init(name: String = "", title: String = "", type: CustomCommandKind = .terminal,
                directory: String = "~/", target: String = "", arguments: String = "",
                terminal: CustomCommandTerminal = .terminal) {
        self.name = name
        self.title = title
        self.type = type
        self.directory = directory
        self.target = target
        self.arguments = arguments
        self.terminal = terminal
    }

    public func validated(reservedNames: Set<String>) throws -> CustomCommand {
        guard ![name, title, directory, target, arguments].contains(where: { $0.contains("\0") }) else {
            throw CustomCommandError.invalidData("自定义命令字段不能包含 NUL 字符。")
        }
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.directory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        result.target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        result.arguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.name.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil else {
            throw CustomCommandError.invalidData("命令名须以字母开头，仅含字母、数字、短横线或下划线。")
        }
        guard !reservedNames.contains(where: { $0.lowercased() == result.name }) else {
            throw CustomCommandError.invalidData("该名称由内置命令保留，请换一个名称。")
        }
        guard !result.title.isEmpty, !result.target.isEmpty else {
            throw CustomCommandError.invalidData("名称与执行内容不能为空。")
        }
        if type != .url {
            guard result.directory.hasPrefix("/") || result.directory.hasPrefix("~/") else {
                throw CustomCommandError.invalidData("工作目录请填写绝对路径或 ~/ 开头的路径。")
            }
        }
        if type == .program {
            guard result.target.hasPrefix("/") || result.target.hasPrefix("~/") else {
                throw CustomCommandError.invalidData("程序或脚本请填写绝对路径或 ~/ 开头的路径。")
            }
        }
        if type == .terminal && terminal == .none {
            throw CustomCommandError.invalidData("终端命令必须选择可用的终端应用。")
        }
        if type == .url {
            let template = result.target.replacingOccurrences(of: "{query}", with: "query")
            guard !template.contains(where: { $0.isWhitespace }),
                  let url = URLComponents(string: template),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.url != nil else {
                throw CustomCommandError.invalidData("网址模板必须是有效的 http 或 https 地址，可使用 {query}。")
            }
        }
        return result
    }
}
