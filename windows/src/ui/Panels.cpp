#include "Launcher.h"
#include "core/Calculator.h"
#include "core/EdgeBookmarks.h"
#include <shellapi.h>
#include <shlobj.h>
#include <algorithm>
#include <cctype>

namespace frog {
namespace {
constexpr UINT32 ink = 0x3b3a3e, muted = 0x695e45, green = 0x0d5e3a, teal = 0x126e82, red = 0x7c1823;
struct Command { const char* name; const char* summary; const char* usage; };
constexpr Command commands[]{
    {"add", "添加书签 · URL → title → location；新文件夹与书签一次保存", ":add"},
    {"edit", "编辑书签 · Tab切字段；Enter一次保存标题与网址", ":edit [title|url]"},
    {"rename", "重命名文件夹 · 非空、60字以内、不能重名", ":rename"},
    {"mkdir", "创建文件夹 · 空参数进入提示流", ":mkdir [名称]"},
    {"move", "移动书签 · 根目录 / 现有文件夹 / 新建文件夹", ":move"},
    {"delete", "删除所选项 · y确认；N/Enter/Esc取消；只删空文件夹", ":delete"},
    {"open", "打开书签或展开/折叠文件夹", ":open"},
    {"copy", "复制所选书签完整网址", ":copy"},
    {"find", "跨文件夹搜索标题和网址 · 无结果Enter网页搜索", ":find [关键词]"},
    {"calc", "计算器 · 四则运算/括号；Enter计算；c复制", ":calc [clear]"},
    {"group", "展开并定位文件夹；根目录折叠全部", ":group 名称"},
    {"backup", "导出真实JSON快照；不包含本机偏好", ":backup [文件路径]"},
    {"restore", "校验并整体替换全部书签与文件夹（不合并）", ":restore [文件路径]"},
    {"import", "只读合并Edge；文件夹压平，同名组合并，网址去重", ":import edge [数据目录]"},
    {"cd", "切换数据目录；空目录写入当前数据；旧目录保留", ":cd [目录路径]"},
    {"set", "本机设置 · login / hotkey / corner / data", ":set [设置项] [值]"},
    {"retry", "重新读取真实数据；读取失败保留已载入数据", ":retry"},
    {"clear", "清空本次运行日志，不修改书签", ":clear"},
    {"help", "命令帮助与键位", ":help"},
    {"log", "本次运行真实日志，最多200条", ":log"},
    {"q", "退出青蛙导航", ":q"}
};
std::pair<std::string, std::string> split(const std::string& raw) {
    auto value = trim(raw); auto at = value.find_first_of(" \t\r\n");
    return {lower(value.substr(0, at)), at == std::string::npos ? "" : trim(value.substr(at + 1))};
}
std::string checkedTitle(const std::string& value) { auto title = trim(value); require(!title.empty() && characters(title) <= 120, "标题不能为空，且不能超过120字。"); return title; }
std::string checkedFolder(const std::string& value, const Document& data, const std::string& excluding = {}) {
    auto name = trim(value); require(!name.empty() && characters(name) <= 60, "文件夹名称不能为空，且不能超过60字。");
    for (const auto& group : data.groups) require(group.id == excluding || group.name != name, "已存在同名文件夹 “" + name + "”。");
    return name;
}
std::string clockText() { SYSTEMTIME t{}; GetLocalTime(&t); char value[16]{}; sprintf_s(value, "%02u:%02u:%02u", t.wHour, t.wMinute, t.wSecond); return value; }
std::string titleFromUrl(const std::string& url) { auto at = url.find("://"); at = at == std::string::npos ? 0 : at + 3; return url.substr(at, url.find_first_of("/?#", at) - at); }
void commandHints(const std::string& value, std::vector<TerminalChoice>& out) {
    out.clear(); if (value.find_first_of(" \t") != std::string::npos) return;
    auto prefix = lower(value);
    for (const auto& command : commands) if (std::string_view(command.name).starts_with(prefix)) { out.push_back({command.name, command.summary, command.usage}); if (out.size() == 3) break; }
}
}
bool Launcher::textInputActive() const { return input_ == TerminalInput::command || input_ == TerminalInput::search || input_ == TerminalInput::calc || (input_ == TerminalInput::prompt && prompt_ && prompt_->acceptsText); }
void Launcher::setInput(TerminalInput kind, const std::string& value) {
    if (kind == TerminalInput::command && input_ != TerminalInput::command) { historyIndex_ = -1; historyDraft_.clear(); completionPrefix_.clear(); lastCompletion_.clear(); }
    input_ = kind; inputText_ = value;
    updateHover(-1, -1);
    if (kind == TerminalInput::command) commandHints(value, commandHints_); else commandHints_.clear();
    changingInput_ = true; if (search_ && windowText(search_) != wide(value)) SetWindowTextW(search_, wide(value).c_str()); changingInput_ = false;
    auto length = static_cast<DWORD>(wide(value).size()); savedSelectionStart_ = savedSelectionEnd_ = length;
    layoutInput();
    if (visible_ && search_) { if (textInputActive()) { SetFocus(search_); SendMessageW(search_, EM_SETSEL, length, length); } else SetFocus(window_); }
    syncAccessibility(); invalidate();
}
void Launcher::inputChanged() {
    if (changingInput_ || composing_ || !textInputActive() || busy_) return;
    auto raw = windowText(search_); auto value = utf8(raw);
    if (input_ == TerminalInput::command) commandHints(value, commandHints_);
    if (input_ == TerminalInput::calc) {
        auto normalized = calculator::normalize(value);
        if (normalized != value) {
            DWORD start{}, end{}; SendMessageW(search_, EM_GETSEL, reinterpret_cast<WPARAM>(&start), reinterpret_cast<LPARAM>(&end));
            // Normalization replaces single UTF-16 units; selection offsets stay unchanged.
            changingInput_ = true; SetWindowTextW(search_, wide(normalized).c_str()); SendMessageW(search_, EM_SETSEL, start, end); changingInput_ = false;
        }
        inputText_ = normalized; calcExpression_ = normalized; calcHistoryIndex_ = -1; calcError_.clear(); calcFeedback_.clear(); updateCalcPreview();
    } else {
        inputText_ = value;
        if (input_ == TerminalInput::search) { query_ = value; selection_ = scroll_ = 0; rebuildItems("__reset__"); }
        else if (input_ == TerminalInput::prompt) { prompt_->error.clear(); captureDraft(); refreshChoices(true); }
        else { historyIndex_ = -1; lastCompletion_.clear(); completionPrefix_.clear(); }
    }
    SendMessageW(search_, EM_GETSEL, reinterpret_cast<WPARAM>(&savedSelectionStart_), reinterpret_cast<LPARAM>(&savedSelectionEnd_));
    syncAccessibility(); invalidate();
}
void Launcher::startSearch() { if (busy_ || prompt_) return; buffer_ = TerminalBuffer::none; organizing_ = false; selection_ = scroll_ = 0; setInput(TerminalInput::search, query_); rebuildItems("__reset__"); }
void Launcher::submitInput() {
    if (busy_) return;
    if (prompt_) { if (prompt_->acceptsText) submitPrompt(); else if (prompt_->command != "hotkey") finishPrompt(); return; }
    if (input_ == TerminalInput::calc) { submitCalc(); return; }
    if (input_ == TerminalInput::command) {
        auto command = trim(inputText_); setInput(TerminalInput::none);
        if (!command.empty()) { history_.push_back(command); if (history_.size() > 50) history_.erase(history_.begin()); runCommand(command); }
        if (buffer_ == TerminalBuffer::calc && !prompt_ && input_ == TerminalInput::none) setInput(TerminalInput::calc, calcExpression_);
    } else if (input_ == TerminalInput::search) { if (trim(query_).empty()) escape(); else activate(); }
}
void Launcher::runCommand(const std::string& raw) {
    if (busy_ || prompt_) return;
    auto value = trim(raw); if (value.starts_with(':')) value.erase(0, 1); if (value.empty()) return;
    auto [name, argument] = split(value); appendLog(":" + value, teal);
    try {
        if (name == "add" || name == "rename" || name == "move" || name == "delete") beginAction(name);
        else if (name == "edit") { require(argument.empty() || argument == "title" || argument == "url", "用法：:edit [title|url]"); beginAction(name, argument == "url"); }
        else if (name == "mkdir") { beginAction(name); if (!argument.empty()) { setInput(TerminalInput::prompt, argument); submitPrompt(); } }
        else if (name == "open") { require(argument.empty(), "用法：:open；命令作用于当前选中项。"); buffer_ = TerminalBuffer::none; activate(); }
        else if (name == "copy") copySelection();
        else if (name == "find") { query_ = argument; startSearch(); }
        else if (name == "group") {
            require(!argument.empty(), "用法：:group 文件夹名称 / 根目录");
            if (argument == "根目录" || argument == "root" || argument == "/") { buffer_ = TerminalBuffer::none; query_.clear(); scroll_ = 0; expanded_.clear(); persistExpanded(); rebuildItems(); appendLog("折叠全部文件夹"); }
            else {
                const Group* exact = nullptr; std::vector<const Group*> matches;
                for (const auto& group : snapshot_.document.groups) { if (group.name == argument) exact = &group; if (group.name.starts_with(argument)) matches.push_back(&group); }
                auto group = exact ? exact : matches.size() == 1 ? matches.front() : nullptr;
                require(group != nullptr, matches.size() > 1 ? "多个文件夹匹配，请输入完整名称。" : "找不到文件夹 “" + argument + "”。");
                buffer_ = TerminalBuffer::none; query_.clear(); scroll_ = 0;
                auto id = group->id; expanded_.insert(id); persistExpanded(); rebuildItems(id); appendLog("已展开并定位文件夹 " + group->name);
            }
        } else if (name == "backup" || name == "restore" || name == "cd") { beginFilePrompt(name, argument); if (!argument.empty()) submitPrompt(); }
        else if (name == "import") { auto [source, path] = split(argument); require(source == "edge", "用法：:import edge [数据目录]"); runEdgeImport(path.empty() ? edge::defaultDataRoot() : resolvedPath(path)); }
        else if (name == "calc" || name == "calculator") {
            if (argument.empty()) openCalc();
            else if (lower(argument) == "clear") { calcExpression_.clear(); calcHistory_.clear(); calcHistoryIndex_ = -1; calcError_.clear(); calcPreview_.clear(); calcFeedback_.clear(); bufferOffset_ = 0; if (buffer_ == TerminalBuffer::calc) setInput(TerminalInput::calc); appendLog("计算器已清空", green); }
            else throw Error("用法：:calc 打开计算器，:calc clear 清空。");
        } else if (name == "set") runSetting(argument);
        else if (name == "help") openBuffer(TerminalBuffer::help);
        else if (name == "log") openBuffer(TerminalBuffer::log);
        else if (name == "retry") { appendLog("重新读取真实数据文件…"); reload(); }
        else if (name == "clear") { logs_.clear(); if (buffer_ == TerminalBuffer::log) bufferOffset_ = 0; refreshBuffer(); }
        else if (name == "q") quit();
        else throw Error("未知命令 “" + name + "” · 输入 :help 查看命令。");
    } catch (const std::exception& e) { notify(e.what(), true); }
    syncAccessibility(); invalidate();
}
void Launcher::completeCommand(bool backward) {
    if (lastCompletion_ != inputText_) completionPrefix_ = inputText_;
    std::vector<std::string> candidates;
    if (completionPrefix_.starts_with("set ")) {
        for (const auto* candidate : {"set login on", "set login off", "set login approve", "set hotkey on", "set hotkey off", "set hotkey reset", "set hotkey record", "set corner on", "set corner off", "set corner left-up", "set corner left-down", "set corner right-up", "set corner right-down", "set data "}) if (std::string_view(candidate).starts_with(completionPrefix_)) candidates.emplace_back(candidate);
    } else for (const auto& command : commands) if (std::string_view(command.name).starts_with(completionPrefix_)) candidates.emplace_back(command.name);
    if (candidates.empty()) return;
    auto previous = std::find(candidates.begin(), candidates.end(), lastCompletion_); int count = static_cast<int>(candidates.size());
    int next = previous == candidates.end() ? backward ? count - 1 : 0 : (static_cast<int>(previous - candidates.begin()) + (backward ? -1 : 1) + count) % count;
    lastCompletion_ = candidates[next]; setInput(TerminalInput::command, lastCompletion_);
}
void Launcher::recallHistory(int delta) {
    if (history_.empty()) return; if (historyIndex_ < 0) historyDraft_ = inputText_;
    int next = std::clamp((historyIndex_ < 0 ? static_cast<int>(history_.size()) : historyIndex_) + delta, 0, static_cast<int>(history_.size()));
    historyIndex_ = next == static_cast<int>(history_.size()) ? -1 : next; setInput(TerminalInput::command, historyIndex_ < 0 ? historyDraft_ : history_[historyIndex_]);
}
void Launcher::openBuffer(TerminalBuffer buffer) {
    if (busy_ || prompt_) return; if (buffer == TerminalBuffer::calc) { openCalc(); return; }
    cancelDrag(); buffer_ = buffer; bufferOffset_ = 0; refreshBuffer(); setInput(TerminalInput::none);
}
void Launcher::refreshBuffer() {
    if (buffer_ != TerminalBuffer::settings && buffer_ != TerminalBuffer::help) return;
    bufferLines_.clear();
    auto add = [this](const std::string& value, UINT32 color = ink) { bufferLines_.push_back({{}, value, color}); };
    if (buffer_ == TerminalBuffer::settings) {
        add("# 本机偏好 · 不随书签同步，不进入备份", muted); add(""); add("[general] · 通用", green);
        bool login = !options_.isolated && loginStartupRegistered(), disabled = !options_.isolated && loginStartupDisabled();
        add(std::string("login\t") + (disabled ? "系统已禁用，需批准" : login ? "on" : "off") + "\t:set login on/off/approve");
        if (options_.isolated) add("# 隔离运行：不允许修改系统登录项；本机偏好不写入正式配置。", muted);
        if (auto error = settingErrors_.find("login"); error != settingErrors_.end()) add("# ! login: " + error->second, red);
        add("hotkey\t" + (preferences_.hotkey.enabled ? utf8(hotkeyName(preferences_.hotkey)) : "off") + "\t:set hotkey record/reset/on/off");
        if (!hotkeyError_.empty()) add("# ! " + hotkeyError_, red);
        std::string corner = !preferences_.cornersEnabled ? "off" : preferences_.corners == 1 ? "左上" : preferences_.corners == 2 ? "右上" : preferences_.corners == 4 ? "左下" : preferences_.corners == 8 ? "右下" : "未选择角落";
        add("corner\t" + corner + "\t:set corner left-up/left-down/right-up/right-down/on/off");
        if (auto error = settingErrors_.find("corner"); error != settingErrors_.end()) add("# ! corner: " + error->second, red);
        if (auto error = settingErrors_.find("preferences"); error != settingErrors_.end()) add("# ! preferences: " + error->second, red);
        add(""); add("[data] · 书签数据", green);
        add("file\t" + utf8((preferences_.dataDirectory / L"bookmarks.json").wstring()) + "\t:cd <目录>");
        add("# 文件名固定为 bookmarks.json；:cd 切换存放目录，旧目录保留。", muted);
        if (!issue_.empty()) add("# ! " + issue_, red);
        add("bookmarks\t" + std::to_string(snapshot_.document.bookmarks.size()) + "\t"); add("groups\t" + std::to_string(snapshot_.document.groups.size()) + "\t");
        add(""); add("[operations] · 数据操作", green);
        add("导出书签与文件夹JSON副本；不改变当前数据目录。", ink); add("backup\t另存真实数据快照\t:backup [文件路径]");
        add("restore\t整体替换全部书签与文件夹（不合并）\t:restore [文件路径]");
        add("import\t只读合并Edge收藏；跳过重复网址\t:import edge [数据目录]");
        add("retry\t重新读取数据文件\t:retry"); add("log\t" + std::to_string(logs_.size()) + " lines\t:log / :clear");
    } else {
        helpCommands_.clear();
        for (const auto& command : commands) helpCommands_.push_back({command.name, command.summary, command.usage});
    }
    syncAccessibility(); invalidate();
}
void Launcher::beginPrompt(const std::string& command, const std::string& field, const std::string& value, int step, int total, bool acceptsText) {
    TerminalPrompt prompt; prompt.command = command; prompt.field = field; prompt.step = step; prompt.total = total; prompt.acceptsText = acceptsText;
    if (command == "edit") prompt.hint = "Tab/Shift+Tab 切换字段 · Enter 保存全部 · Esc 取消";
    else if (command == "delete") prompt.hint = "删除 “" + draft_.title + "”？ y 删除 · N/Enter/Esc 取消";
    else if (command == "hotkey") prompt.hint = "按下新的组合键 · Esc 取消";
    else if (field == "location" || field == "to") prompt.hint = "Tab/上下选择 · Shift+Tab 返回 · Enter 选择 · Esc 取消";
    else if (command == "restore") prompt.hint = "Enter 恢复并替换全部书签与文件夹 · Tab 补全 · Esc 取消";
    else if (field == "path" || field == "file") prompt.hint = "Enter 提交 · Tab/上下补全真实路径 · Esc 取消";
    else if (command == "add" || command == "move") prompt.hint = "Enter 下一步/保存 · Shift+Tab 返回 · Esc 取消";
    else prompt.hint = "Enter 提交 · Esc 取消";
    prompt_ = std::move(prompt); setInput(TerminalInput::prompt, value); refreshChoices(false);
}
void Launcher::beginAction(const std::string& command, bool urlFirst) {
    if (busy_ || prompt_) return;
    const auto* row = selectedRow(); draft_ = {}; draft_.expected = snapshot_.bytes;
    if (command == "add") { buffer_ = TerminalBuffer::none; beginPrompt(command, "url", "", 0, 3); return; }
    if (command == "mkdir") { beginPrompt(command, "name", ""); return; }
    require(row != nullptr, "请选择书签或文件夹。"); draft_.id = row->id; draft_.isFolder = row->folder; draft_.title = row->title;
    if (command == "rename") { require(row->folder, "请选择文件夹。"); draft_.folder = row->title; beginPrompt(command, "name", draft_.folder); return; }
    if (command == "delete") {
        require(!row->folder || snapshot_.document.items(row->id).empty(), "请先移出或删除文件夹内的书签，再删除文件夹。");
        beginPrompt(command, "confirm", "", 0, 0, false); return;
    }
    require(!row->folder, "请选择书签。"); auto bookmark = snapshot_.document.bookmark(row->id); require(bookmark != nullptr, "书签已不存在。");
    draft_.url = bookmark->url; draft_.title = bookmark->title; draft_.titleInitialized = true; draft_.location = bookmark->groupId.value_or("__root__");
    if (command == "edit") beginPrompt(command, urlFirst ? "url" : "title", urlFirst ? draft_.url : draft_.title, urlFirst ? 1 : 0, 2);
    else if (command == "move") { draft_.location.clear(); beginPrompt(command, "to", ""); showLocation(); }
}
void Launcher::finishPrompt() {
    bool recording = prompt_ && prompt_->command == "hotkey"; ++choiceGeneration_; prompt_.reset(); draft_ = {};
    if (recording) try { hotkey_.set(controller_, preferences_.hotkey); hotkeyError_.clear(); } catch (const std::exception& error) { hotkeyError_ = error.what(); appendLog(hotkeyError_, red); }
    setInput(buffer_ == TerminalBuffer::calc ? TerminalInput::calc : TerminalInput::none, buffer_ == TerminalBuffer::calc ? calcExpression_ : ""); refreshBuffer();
}
void Launcher::captureDraft() {
    if (!prompt_) return;
    if (prompt_->field == "title") { draft_.title = inputText_; draft_.titleInitialized = true; } else if (prompt_->field == "url") draft_.url = inputText_;
    else if (prompt_->field == "name" || prompt_->field == "folder") draft_.folder = inputText_;
    else if (prompt_->field == "path" || prompt_->field == "file") draft_.path = inputText_;
}
void Launcher::switchEditField() { if (!prompt_ || prompt_->command != "edit" || busy_) return; captureDraft(); bool url = prompt_->field == "title"; beginPrompt("edit", url ? "url" : "title", url ? draft_.url : draft_.title, url ? 1 : 0, 2); }
void Launcher::previousPrompt() {
    if (!prompt_ || busy_) return; captureDraft(); auto command = prompt_->command; int step = prompt_->step;
    if (command == "add") { if (step == 1) beginPrompt(command, "url", draft_.url, 0, 3); else if (step == 2) beginPrompt(command, "title", draft_.title, 1, 3); else if (step == 3) showLocation(); }
    else if (command == "move" && step == 1) showLocation();
    else if (prompt_->field == "path" || prompt_->field == "file") cycleChoice(-1);
}
void Launcher::showLocation() {
    if (!prompt_) return; auto command = prompt_->command;
    beginPrompt(command, command == "add" ? "location" : "to", "", command == "add" ? 2 : 0, command == "add" ? 3 : 0);
    if (!prompt_->choices.empty()) chooseOption(prompt_->selected);
}
void Launcher::refreshChoices(bool filter) {
    if (!prompt_) return;
    if (prompt_->field == "location" || prompt_->field == "to") {
        std::vector<TerminalChoice> choices{{"__root__", "根目录", ""}}; std::vector<const Group*> groups;
        for (const auto& group : snapshot_.document.groups) groups.push_back(&group);
        std::sort(groups.begin(), groups.end(), [](auto a, auto b) { return a->order == b->order ? a->id < b->id : a->order < b->order; });
        for (auto group : groups) choices.push_back({group->id, group->name, std::to_string(snapshot_.document.items(group->id).size()) + " bookmarks"});
        choices.push_back({"__new__", "新建文件夹…", "先命名，再原子保存"});
        if (prompt_->command == "move") if (auto bookmark = snapshot_.document.bookmark(draft_.id)) std::erase_if(choices, [&](const auto& choice) { return choice.id == bookmark->groupId.value_or("__root__"); });
        auto needle = lower(trim(inputText_));
        if (filter && !needle.empty()) std::erase_if(choices, [&](const auto& choice) { return lower(choice.label).find(needle) == std::string::npos; });
        prompt_->choices = std::move(choices); prompt_->selected = 0;
        for (size_t i = 0; i < prompt_->choices.size(); ++i) if (prompt_->choices[i].id == draft_.location) prompt_->selected = static_cast<int>(i);
        syncAccessibility(); invalidate();
    } else if (prompt_->field == "path" || prompt_->field == "file") {
        auto generation = ++choiceGeneration_; auto raw = inputText_; auto command = prompt_->command; fs::path full;
        try { full = resolvedPath(raw.empty() ? "." : raw); } catch (const std::exception&) { prompt_->choices.clear(); return; }
        bool trailing = raw.empty() || raw.back() == '/' || raw.back() == '\\'; auto parent = trailing ? full : full.parent_path(); auto prefix = trailing ? "" : lower(utf8(full.filename().wstring()));
        prompt_->choices.clear(); prompt_->selected = 0;
        storageQueue_->post([this, generation, raw, command, parent, prefix] {
            std::vector<TerminalChoice> choices; std::error_code ec;
            for (fs::directory_iterator it(parent, fs::directory_options::skip_permission_denied, ec), end; !ec && it != end; it.increment(ec)) {
                auto path = it->path(); auto name = utf8(path.filename().wstring()); if (!prefix.empty() && lower(name).find(prefix) == std::string::npos) continue;
                bool directory = it->is_directory(ec); if (ec) break;
                if (!directory && (command == "cd" || !it->is_regular_file(ec) || lower(utf8(path.extension().wstring())) != ".json")) continue;
                auto value = utf8(path.wstring()) + (directory ? "\\" : ""); choices.push_back({value, value, directory ? "directory" : "JSON"});
            }
            std::sort(choices.begin(), choices.end(), [](const auto& a, const auto& b) { return a.detail != b.detail ? a.detail == "directory" : lower(a.label) < lower(b.label); });
            dispatch([this, generation, raw, choices = std::move(choices)]() mutable { if (generation != choiceGeneration_ || !prompt_ || inputText_ != raw) return; prompt_->choices = std::move(choices); prompt_->selected = 0; syncAccessibility(); invalidate(); });
        });
    }
}
void Launcher::chooseOption(int index) {
    if (!prompt_ || busy_ || index < 0 || index >= static_cast<int>(prompt_->choices.size())) return;
    auto choice = prompt_->choices[index]; prompt_->selected = index; prompt_->error.clear();
    if (prompt_->field == "location" || prompt_->field == "to") draft_.location = choice.id;
    setInput(TerminalInput::prompt, choice.label); captureDraft();
    if ((prompt_->field == "path" || prompt_->field == "file") && choice.detail == "directory") refreshChoices(false);
}
void Launcher::cycleChoice(int delta) {
    if (!prompt_ || prompt_->choices.empty()) return; int count = static_cast<int>(prompt_->choices.size());
    bool filled = prompt_->selected >= 0 && prompt_->selected < count && prompt_->choices[prompt_->selected].label == inputText_;
    chooseOption(filled ? (prompt_->selected + delta + count) % count : delta < 0 ? count - 1 : prompt_->selected);
}
void Launcher::submitPrompt() {
    if (!prompt_ || busy_) return; captureDraft(); auto command = prompt_->command;
    try {
        if (command == "add") {
            if (prompt_->step == 0) { draft_.url = normalizeUrl(draft_.url); if (!draft_.titleInitialized) { draft_.title = titleFromUrl(draft_.url); draft_.titleInitialized = true; } beginPrompt(command, "title", draft_.title, 1, 3); }
            else if (prompt_->step == 1) { draft_.title = checkedTitle(draft_.title); showLocation(); }
            else if (prompt_->step == 2) {
                require(!prompt_->choices.empty(), "请选择一个有效位置。"); draft_.location = prompt_->choices[prompt_->selected].id;
                if (draft_.location == "__new__") beginPrompt(command, "folder", draft_.folder, 3, 4); else saveBookmark();
            } else { checkedFolder(draft_.folder, snapshot_.document); saveBookmark(); }
        } else if (command == "edit") {
            try { draft_.title = checkedTitle(draft_.title); }
            catch (const std::exception& e) { if (prompt_->field != "title") beginPrompt(command, "title", draft_.title, 0, 2); throw Error(e.what()); }
            try { draft_.url = normalizeUrl(draft_.url); }
            catch (const std::exception& e) { if (prompt_->field != "url") beginPrompt(command, "url", draft_.url, 1, 2); throw Error(e.what()); }
            saveBookmark();
        } else if (command == "rename" || command == "mkdir") {
            auto name = checkedFolder(draft_.folder, snapshot_.document, draft_.id); auto id = std::make_shared<std::string>(draft_.id);
            mutate([name, id, command](Document& data) { checkedFolder(name, data, *id); if (command == "rename") { require(data.group(*id) != nullptr, "文件夹已被外部删除；草稿已保留。"); data.renameGroup(*id, name); } else *id = data.addGroup(name); },
                [this, id, name] { finishPrompt(); rebuildItems(*id); appendLog("已保存文件夹 “" + name + "”", green); }, draft_.expected);
        } else if (command == "move") {
            if (prompt_->step == 0) { require(!prompt_->choices.empty(), "请选择一个有效目标。"); draft_.location = prompt_->choices[prompt_->selected].id; if (draft_.location == "__new__") { beginPrompt(command, "name", draft_.folder, 1, 2); return; } }
            else checkedFolder(draft_.folder, snapshot_.document);
            auto draft = draft_; auto destination = std::make_shared<Location>();
            mutate([draft, destination](Document& data) { require(data.bookmark(draft.id) != nullptr, "书签已被外部删除；草稿已保留。"); if (draft.location == "__new__") *destination = data.addGroup(checkedFolder(draft.folder, data)); else if (draft.location != "__root__") *destination = draft.location; data.move(draft.id, *destination); },
                [this, id = draft.id, destination] { if (*destination) expanded_.insert(**destination); persistExpanded(); finishPrompt(); rebuildItems(id); appendLog("已移动书签", green); }, draft.expected);
        } else if (command == "backup" || command == "restore" || command == "cd") runFileOperation(command, resolvedPath(draft_.path));
    } catch (const std::exception& e) { notify(e.what(), true); }
    syncAccessibility(); invalidate();
}
void Launcher::saveBookmark() {
    auto draft = draft_; auto id = std::make_shared<std::string>(); auto destination = std::make_shared<Location>();
    mutate([draft, id, destination](Document& data) {
        if (!draft.id.empty()) { auto bookmark = data.bookmark(draft.id); require(bookmark != nullptr, "该书签已被外部删除；未提交输入仍保留。"); *destination = bookmark->groupId; }
        else if (draft.location != "__root__" && draft.location != "__new__") *destination = draft.location;
        auto newFolder = draft.location == "__new__" ? checkedFolder(draft.folder, data) : "";
        *id = data.upsert(draft.id, checkedTitle(draft.title), normalizeUrl(draft.url), *destination, newFolder);
        if (auto bookmark = data.bookmark(*id)) *destination = bookmark->groupId;
    }, [this, id, destination, title = draft.title] { if (*destination) expanded_.insert(**destination); persistExpanded(); finishPrompt(); rebuildItems(*id); appendLog("已保存 “" + title + "”", green); }, draft.expected);
}
void Launcher::confirmDelete() {
    if (!prompt_ || prompt_->command != "delete" || busy_) return; auto id = draft_.id; auto title = draft_.title; bool folder = draft_.isFolder;
    mutate([id, folder](Document& data) { require(folder ? data.group(id) != nullptr : data.bookmark(id) != nullptr, "条目已被外部删除。"); require(!folder || data.items(id).empty(), "文件夹已包含书签，不能删除。"); data.remove(id); },
        [this, id, title] { expanded_.erase(id); persistExpanded(); finishPrompt(); rebuildItems(); appendLog("已删除 “" + title + "”", green); }, draft_.expected);
}
fs::path Launcher::resolvedPath(const std::string& raw) const {
    auto value = trim(raw); if (value.size() >= 2 && (value.front() == '\'' || value.front() == '"') && value.back() == value.front()) value = value.substr(1, value.size() - 2);
    require(!value.empty(), "路径不能为空。");
    if (value == "~" || value.starts_with("~/") || value.starts_with("~\\")) { wchar_t home[32768]{}; DWORD count = GetEnvironmentVariableW(L"USERPROFILE", home, static_cast<DWORD>(std::size(home))); require(count > 0 && count < std::size(home), "无法读取用户主目录。"); value = utf8(std::wstring(home)) + value.substr(1); }
    fs::path path(wide(value)); if (path.is_relative()) path = preferences_.dataDirectory / path; return fs::absolute(path).lexically_normal();
}
void Launcher::beginFilePrompt(const std::string& command, const std::string& argument) {
    if (busy_ || prompt_) return; draft_ = {}; draft_.expected = snapshot_.bytes;
    auto value = argument;
    if (value.empty()) {
        if (command == "backup") {
            SYSTEMTIME t{}; GetLocalTime(&t); wchar_t filename[100]{}; swprintf_s(filename, L"青蛙导航-Bookmarks-%04u%02u%02u-%02u%02u%02u.json", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
            PWSTR documents{}; check(SHGetKnownFolderPath(FOLDERID_Documents, KF_FLAG_DEFAULT, nullptr, &documents), "无法读取文稿目录。");
            ScopeExit freePath{[&] { CoTaskMemFree(documents); }}; value = utf8((fs::path(documents) / filename).wstring());
        } else value = utf8(preferences_.dataDirectory.wstring()) + "\\";
    }
    draft_.path = value; beginPrompt(command, command == "restore" ? "file" : "path", value);
}
void Launcher::runFileOperation(const std::string& command, const fs::path& path) {
    require(!busy_, "正在处理数据。"); require(loaded_ || command == "cd", "当前数据未能读取；请先 :retry 或 :cd。");
    busy_ = true; buffer_ = TerminalBuffer::job; bufferOffset_ = 0; jobTitle_ = command; jobStatus_ = "RUNNING";
    jobLines_ = {{clockText(), ":" + command + " " + utf8(path.wstring()), teal}, {clockText(), command == "backup" ? "校验并导出当前真实数据…" : "读取并校验真实数据文件…", ink}};
    auto document = snapshot_.document; auto expected = draft_.expected.empty() ? snapshot_.bytes : draft_.expected; auto oldDirectory = preferences_.dataDirectory;
    auto prefs = preferences_; auto options = options_; layoutInput(); syncAccessibility(); invalidate();
    storageQueue_->post([this, command, path, document = std::move(document), expected, oldDirectory, prefs, options]() mutable {
        try {
            std::optional<Snapshot> result;
            if (command == "backup") storage_.backup(path, document);
            else if (command == "restore") result = storage_.restore(path, expected);
            else {
                // Preference failure must not leave Storage pointing at a different directory.
                result = storage_.open(path, false, document);
                try { prefs.dataDirectory = result->directory; prefs.save(options); }
                catch (const std::exception& error) {
                    std::string message = error.what();
                    try { storage_.open(oldDirectory, false, {}, false); }
                    catch (const std::exception& restoreError) { message += "；原目录恢复失败："; message += restoreError.what(); dispatch([this] { loaded_ = false; }); }
                    throw Error(message);
                }
            }
            dispatch([this, command, path, result = std::move(result), prefs]() mutable {
                busy_ = false; issue_.clear(); if (command == "cd") preferences_ = prefs;
                if (result) { query_.clear(); selection_ = scroll_ = 0; organizing_ = false; applySnapshot(std::move(*result)); }
                auto message = command == "backup" ? "备份已保存至 " + utf8(path.wstring()) : command == "restore" ? "已整体恢复 " + std::to_string(snapshot_.document.bookmarks.size()) + " 条书签与 " + std::to_string(snapshot_.document.groups.size()) + " 个文件夹；数据目录未改变。" : "数据目录：" + utf8(snapshot_.directory.wstring()) + "；旧目录数据保留。";
                finishPrompt(); jobStatus_ = "DONE"; jobLines_.push_back({clockText(), message, green}); jobLines_.push_back({clockText(), "exit 0", muted}); appendLog(message, green); diagnostics_.event("saved"); syncAccessibility(); invalidate();
                if (reloadPending_) { reloadPending_ = false; reload(); }
            });
        } catch (const Conflict& e) {
            std::optional<Snapshot> current; try { current = storage_.reload(); } catch (const std::exception&) {}
            dispatch([this, current = std::move(current), message = std::string(e.what())]() mutable { busy_ = false; if (current) applySnapshot(std::move(*current)); draft_.expected = snapshot_.bytes; jobStatus_ = "ERROR"; jobLines_.push_back({clockText(), message, red}); jobLines_.push_back({clockText(), "exit 1", red}); notify(message + " 草稿已保留，核对后Enter重试。", true); diagnostics_.event("save_conflict"); });
        } catch (const std::exception& e) { dispatch([this, message = std::string(e.what())] { busy_ = false; jobStatus_ = "ERROR"; jobLines_.push_back({clockText(), message, red}); jobLines_.push_back({clockText(), "exit 1", red}); notify(message + " 当前数据与输入已保留。", true); diagnostics_.event("save_failed", {{"message", message}}); }); }
    });
}
void Launcher::runEdgeImport(const fs::path& path) {
    require(loaded_, "当前数据尚未成功读取。"); require(!busy_, "正在处理数据。"); busy_ = true; buffer_ = TerminalBuffer::job; bufferOffset_ = 0; jobTitle_ = "import edge"; jobStatus_ = "RUNNING";
    jobLines_ = {{clockText(), ":import edge " + utf8(path.wstring()), teal}, {clockText(), "只读扫描Edge收藏；所有配置校验通过后一次保存…", ink}};
    auto document = snapshot_.document; auto expected = snapshot_.bytes; layoutInput(); syncAccessibility(); invalidate();
    storageQueue_->post([this, path, document = std::move(document), expected] {
        try {
            auto imported = edge::importFrom(document, path); auto saved = storage_.save(imported.document, expected);
            dispatch([this, saved = std::move(saved), summary = imported.summary]() mutable {
                busy_ = false; query_.clear(); selection_ = scroll_ = 0; organizing_ = false; applySnapshot(std::move(saved)); jobStatus_ = "DONE";
                auto message = "已扫描 " + std::to_string(summary.profiles) + " 个Edge配置，导入 " + std::to_string(summary.inserted) + " 条书签，新建 " + std::to_string(summary.groups) + " 个文件夹；跳过重复 " + std::to_string(summary.duplicates) + " 条、不支持 " + std::to_string(summary.unsupported) + " 条。";
                jobLines_.push_back({clockText(), message, green}); jobLines_.push_back({clockText(), "exit 0", muted}); appendLog(message, green); layoutInput(); syncAccessibility(); diagnostics_.event("saved"); if (reloadPending_) { reloadPending_ = false; reload(); }
            });
        } catch (const Conflict& e) {
            std::optional<Snapshot> current; try { current = storage_.reload(); } catch (const std::exception&) {}
            dispatch([this, current = std::move(current), message = std::string(e.what())]() mutable { busy_ = false; if (current) applySnapshot(std::move(*current)); jobStatus_ = "ERROR"; jobLines_.push_back({clockText(), message, red}); notify(message + " 请重新执行导入；Edge源文件未改动。", true); diagnostics_.event("save_conflict"); });
        } catch (const std::exception& e) { dispatch([this, message = std::string(e.what())] { busy_ = false; jobStatus_ = "ERROR"; jobLines_.push_back({clockText(), message, red}); jobLines_.push_back({clockText(), "exit 1", red}); notify(message + " 原数据保持不变。", true); layoutInput(); diagnostics_.event("save_failed", {{"message", message}}); }); }
    });
}
void Launcher::updatePreferences(const Preferences& next) {
    auto old = preferences_; std::string stage;
    bool hotkeyChanged = next.hotkey != old.hotkey;
    bool cornerChanged = next.cornersEnabled != old.cornersEnabled || next.corners != old.corners;
    try {
        if (hotkeyChanged || !hotkeyError_.empty()) { stage = "hotkey"; hotkey_.set(controller_, next.hotkey); hotkeyError_.clear(); }
        if (cornerChanged) { stage = "corner"; corners_.configure(controller_, next.cornersEnabled, next.corners); }
        stage = "preferences"; next.save(options_); preferences_ = next; settingErrors_.erase(stage);
    } catch (const std::exception& e) {
        auto message = std::string(e.what());
        try { if (hotkeyChanged) hotkey_.set(controller_, prompt_ && prompt_->command == "hotkey" ? HotKey{false} : old.hotkey); if (cornerChanged) corners_.configure(controller_, old.cornersEnabled, old.corners); }
        catch (const std::exception& rollback) { message += "；恢复原设置失败："; message += rollback.what(); }
        if (stage == "hotkey") hotkeyError_ = message; else settingErrors_[stage] = message;
        refreshBuffer(); throw Error(message);
    }
    refreshBuffer(); invalidate();
}
void Launcher::runSetting(const std::string& argument) {
    if (argument.empty()) { openBuffer(TerminalBuffer::settings); return; }
    auto [key, original] = split(argument); auto value = lower(original); auto prefs = preferences_;
    if (key == "data") { beginFilePrompt("cd", original); if (!original.empty()) submitPrompt(); return; }
    settingErrors_.erase(key);
    try {
    if (key == "login") {
        require(!options_.isolated, "隔离运行：不允许修改系统登录启动或打开正式登录项设置。");
        if (value == "on" || value == "off") { setLoginStartup(value == "on"); appendLog(std::string("登录启动：") + (loginStartupRegistered() ? loginStartupDisabled() ? "已注册，等待系统批准" : "on" : "off")); }
        else if (value == "approve") { require(reinterpret_cast<INT_PTR>(ShellExecuteW(window_, L"open", L"ms-settings:startupapps", nullptr, nullptr, SW_SHOWNORMAL)) > 32, "无法打开Windows启动应用设置。"); appendLog("已打开系统启动应用设置；请在系统中批准后返回。"); }
        else throw Error("用法：:set login on/off/approve");
    } else if (key == "hotkey") {
        if (value == "record") { hotkey_.set(controller_, HotKey{false}); draft_ = {}; beginPrompt("hotkey", "press keys", "", 0, 0, false); return; }
        if (value == "on" || value == "off") prefs.hotkey.enabled = value == "on";
        else if (value == "reset") prefs.hotkey = HotKey{};
        else throw Error("用法：:set hotkey on/off/reset/record");
        updatePreferences(prefs); appendLog("全局快捷键：" + (prefs.hotkey.enabled ? utf8(hotkeyName(prefs.hotkey)) : "off"));
    } else if (key == "corner") {
        if (value == "on" || value == "off") { prefs.cornersEnabled = value == "on"; if (prefs.cornersEnabled && !prefs.corners) prefs.corners = 4; }
        else { unsigned mask = value == "left-up" ? 1 : value == "right-up" ? 2 : value == "left-down" ? 4 : value == "right-down" ? 8 : 0; require(mask != 0, "用法：:set corner on/off/left-up/left-down/right-up/right-down"); prefs.corners = mask; prefs.cornersEnabled = true; }
        updatePreferences(prefs); cornerFlashUntil_ = milliseconds() + 900; SetTimer(window_, 8, 900, nullptr); appendLog("屏幕触角：" + value);
    } else throw Error("未知设置项 “" + key + "” · 可用 login / hotkey / corner / data");
    } catch (const std::exception& error) { settingErrors_[key] = error.what(); refreshBuffer(); throw; }
    refreshBuffer();
}
void Launcher::openCalc() { if (prompt_ || busy_) return; buffer_ = TerminalBuffer::calc; bufferOffset_ = 0; calcHistoryIndex_ = -1; calcError_.clear(); calcFeedback_.clear(); updateCalcPreview(); setInput(TerminalInput::calc, calcExpression_); }
void Launcher::updateCalcPreview() { calcPreview_.clear(); if (!trim(calcExpression_).empty()) try { calcPreview_ = calculator::format(calculator::evaluate(calcExpression_)); } catch (const std::exception&) {} }
void Launcher::submitCalc() {
    if (busy_) return;
    try {
        auto expression = trim(calcExpression_); require(!expression.empty(), "请输入算式"); auto value = calculator::format(calculator::evaluate(expression));
        std::erase_if(calcHistory_, [&](const auto& entry) { return entry.expression == expression; }); calcHistory_.insert(calcHistory_.begin(), {clockText(), expression, value}); if (calcHistory_.size() > 50) calcHistory_.pop_back();
        calcExpression_ = expression; calcPreview_ = value; calcError_.clear(); calcFeedback_.clear(); calcHistoryIndex_ = -1; bufferOffset_ = 0; setInput(TerminalInput::calc, expression);
    } catch (const std::exception& e) { calcError_ = e.what(); syncAccessibility(); invalidate(); }
}
void Launcher::browseCalc(int direction) { if (calcHistory_.empty()) return; int next = calcHistoryIndex_ < 0 ? 0 : calcHistoryIndex_ + direction; if (next >= 0 && next < static_cast<int>(calcHistory_.size())) selectCalc(next); }
void Launcher::selectCalc(int index) {
    if (index < 0 || index >= static_cast<int>(calcHistory_.size()) || prompt_ || busy_) return;
    calcHistoryIndex_ = index; calcExpression_ = calcHistory_[index].expression; calcError_.clear(); calcFeedback_.clear(); updateCalcPreview();
    if (index < bufferOffset_) bufferOffset_ = index; else if (index >= bufferOffset_ + 16) bufferOffset_ = index - 15;
    setInput(TerminalInput::calc, calcExpression_);
}
void Launcher::copyCalc() {
    try { auto value = calcHistoryIndex_ >= 0 ? calcHistory_[calcHistoryIndex_].value : calculator::format(calculator::evaluate(calcExpression_)); copyText(window_, wide(value)); calcFeedback_ = "已复制 " + value; }
    catch (const std::exception& e) { calcFeedback_ = "没有可复制的结果：" + std::string(e.what()); }
    SetTimer(window_, 6, 1400, nullptr); layoutInput(); syncAccessibility(); invalidate();
}
std::string Launcher::promptLabel() const { if (!prompt_) return ""; return prompt_->command + (prompt_->total ? " " + std::to_string(prompt_->step + 1) + "/" + std::to_string(prompt_->total) : "") + " › " + prompt_->field; }
std::string Launcher::inputHint() const {
    if (prompt_) return prompt_->error.empty() ? prompt_->hint : prompt_->error;
    if (input_ == TerminalInput::command) return "Tab 补全 · ↑↓ 历史 · Esc 取消";
    if (input_ == TerminalInput::search) return "Enter 打开 · Esc 清空";
    if (input_ == TerminalInput::calc) return calcFeedback_.empty() ? "Enter 计算 · ↑↓ 历史 · c 复制 · Esc 关闭" : calcFeedback_;
    return "";
}
std::string Launcher::modeLabel() const {
    if (prompt_) return "PROMPT"; if (input_ == TerminalInput::command) return "COMMAND"; if (input_ == TerminalInput::search) return "SEARCH";
    switch (buffer_) { case TerminalBuffer::settings: return "BUFFER:SETTINGS"; case TerminalBuffer::help: return "BUFFER:HELP"; case TerminalBuffer::log: return "BUFFER:LOG"; case TerminalBuffer::job: return "BUFFER:JOB"; case TerminalBuffer::calc: return "BUFFER:CALC"; default: break; }
    if (busy_) return "BUSY"; if (!query_.empty()) return "SEARCH"; return organizing_ ? "ORGANIZE" : "NORMAL";
}
std::string Launcher::shortcuts() const {
    if (busy_) return "正在处理，请稍候…";
    if (prompt_) {
        if (prompt_->command == "hotkey") return "组合键 录入新快捷键    Esc 取消录入";
        if (prompt_->command == "delete") return "y 确认删除    N / Enter / Esc 取消删除";
        if (prompt_->command == "edit") return "Tab / Shift+Tab 切换标题 / 网址    Enter 保存全部    Esc 取消";
        std::string value;
        if (!prompt_->choices.empty()) value = "Tab / ↑↓ " + std::string(prompt_->field == "path" || prompt_->field == "file" ? "补全路径" : "选择位置") + "    ";
        if ((prompt_->command == "add" || prompt_->command == "move") && prompt_->step > 0) value += "Shift+Tab 返回上一步    ";
        value += prompt_->command == "restore" ? "Enter 恢复并替换全部数据" : prompt_->command == "backup" ? "Enter 导出备份" : prompt_->command == "cd" ? "Enter 切换目录" : prompt_->command == "add" && prompt_->step < 2 ? "Enter 下一步" : "Enter 确认保存";
        return value + "    Esc 取消";
    }
    if (input_ == TerminalInput::command) return "Tab / Shift+Tab 补全命令    ↑↓ 命令历史    Enter 执行命令    Esc 取消命令";
    if (input_ == TerminalInput::search) return rows_.empty() ? "Enter 打开网址 / 网页搜索    Esc 清空并退出搜索" : "↑↓ 选择结果    Enter 打开结果    Esc 清空并退出搜索";
    if (buffer_ == TerminalBuffer::calc) return "Enter / = 计算    ↑↓ 选择历史    c 复制结果    : 输入命令    Esc 关闭（保留算式与历史）";
    if (buffer_ == TerminalBuffer::settings) return ": 输入命令    :help 查看帮助    Esc 返回书签";
    if (buffer_ != TerminalBuffer::none) return "j/k / ↑↓ 滚动    g/G 首尾    PgUp/PgDn 翻屏    : 输入命令    Esc 返回书签";
    auto row = selectedRow(); std::string value = "j/k 选择    Enter "; value += row && row->folder ? row->expanded ? "折叠文件夹    Tab 展开/折叠    r 重命名" : "展开文件夹    Tab 展开/折叠    r 重命名" : "打开书签    e 编辑    m 移动    c 复制链接";
    if (organizing_ && row && !row->folder) value += "    Shift+↑/↓ 排序    D 删除";
    else value += "    a 添加    n 文件夹    / 搜索";
    return value + (organizing_ ? "    o/Esc 完成整理" : "    o 整理    Esc 返回/折叠/收起");
}
}
