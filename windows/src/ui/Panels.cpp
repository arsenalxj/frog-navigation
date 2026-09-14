#include "Launcher.h"
#include <commctrl.h>
#include <shellapi.h>
#include <uxtheme.h>
#include <algorithm>

namespace frog {
namespace {
constexpr int inputUrl = 201, inputTitle = 202, inputLocation = 203, inputNewFolder = 204, inputRename = 211;
constexpr int cancelButton = 220, saveButton = 221, closeButton = 230;
D2D1_COLOR_F color(UINT32 rgb, float alpha = 1) { return D2D1::ColorF(rgb, alpha); }
}
Rect Launcher::panelBounds() const {
    float width = panel_ == Panel::settings ? 760.0f : 448.0f;
    float height = panel_ == Panel::settings ? 540.0f : (panel_ == Panel::rename ? 265.0f : (draft_.location == "__new__" ? 494.0f : 416.0f));
    width = std::min(width, view_.layout.width - 30); height = std::min(height, view_.layout.height - 30);
    return {(view_.layout.width - width) / 2, (view_.layout.height - height) / 2, width, height};
}
HWND Launcher::control(const wchar_t* type, const std::wstring& value, DWORD style, int id) {
    auto window = CreateWindowExW(_wcsicmp(type, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, type, value.c_str(), WS_CHILD | WS_VISIBLE | WS_TABSTOP | style, 0, 0, 1, 1, window_, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
    require(window != nullptr, "无法建立原生控件。"); SendMessageW(window, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
    SetWindowTheme(window, theme_.dark ? L"DarkMode_Explorer" : L"Explorer", nullptr);
    SetWindowSubclass(window, controlProc, 1, reinterpret_cast<DWORD_PTR>(this)); controls_[id] = window; return window;
}
void Launcher::moveControl(int id, Rect rect) {
    auto it = controls_.find(id); if (it == controls_.end()) return;
    MoveWindow(it->second, static_cast<int>(rect.x * dpiScale_), static_cast<int>(rect.y * dpiScale_), static_cast<int>(rect.width * dpiScale_), static_cast<int>(rect.height * dpiScale_), TRUE);
}
void Launcher::destroyPanelControls() { for (auto [id, window] : controls_) DestroyWindow(window); controls_.clear(); composing_ = false; }
void Launcher::createPanelControls() {
    destroyPanelControls(); if (panel_ == Panel::none) return;
    EnableWindow(search_, FALSE); EnableWindow(settingsButton_, FALSE); EnableWindow(addButton_, FALSE);
    ShowWindow(search_, SW_HIDE); ShowWindow(settingsButton_, SW_HIDE); ShowWindow(addButton_, SW_HIDE);
    if (panel_ == Panel::bookmark) {
        control(L"EDIT", wide(draft_.url), ES_AUTOHSCROLL, inputUrl); SendMessageW(controls_[inputUrl], EM_SETLIMITTEXT, 8192, 0);
        control(L"EDIT", wide(draft_.title), ES_AUTOHSCROLL, inputTitle); SendMessageW(controls_[inputTitle], EM_SETLIMITTEXT, 2048, 0);
        auto combo = control(L"COMBOBOX", L"位置", CBS_DROPDOWNLIST | WS_VSCROLL, inputLocation); locationChoices_.clear();
        auto add = [&](const std::string& id, const std::string& name) { locationChoices_.push_back(id); SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(wide(name).c_str())); };
        add("", "根目录"); for (const auto& g : snapshot_.document.groups) add(g.id, g.name); add("__new__", "新建文件夹…");
        int selected = 0; for (size_t i = 0; i < locationChoices_.size(); ++i) if (locationChoices_[i] == draft_.location) selected = static_cast<int>(i);
        if (!draft_.location.empty() && draft_.location != "__new__" && !snapshot_.document.group(draft_.location)) { add(draft_.location, "原文件夹已不存在，请重新选择"); selected = static_cast<int>(locationChoices_.size()) - 1; }
        SendMessageW(combo, CB_SETCURSEL, selected, 0);
        control(L"EDIT", wide(draft_.newFolder), ES_AUTOHSCROLL, inputNewFolder);
        SendMessageW(controls_[inputUrl], EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(L"example.com 或 https://example.com"));
        SendMessageW(controls_[inputTitle], EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(L"书签名称（最多 120 个字符）"));
        control(L"BUTTON", L"取消", BS_PUSHBUTTON, cancelButton); control(L"BUTTON", draft_.id.empty() ? L"添加" : L"保存", BS_DEFPUSHBUTTON, saveButton);
    } else if (panel_ == Panel::rename) {
        auto group = snapshot_.document.group(renameId_); control(L"EDIT", group ? wide(group->name) : L"", ES_AUTOHSCROLL, inputRename);
        control(L"BUTTON", L"取消", BS_PUSHBUTTON, cancelButton); control(L"BUTTON", L"保存", BS_DEFPUSHBUTTON, saveButton);
    } else {
        const wchar_t* names[]{L"常规", L"快捷键", L"屏幕触角", L"数据与备份", L"关于"};
        for (int i = 0; i < 5; ++i) control(L"BUTTON", names[i], BS_PUSHBUTTON, 300 + i);
        control(L"BUTTON", L"关闭", BS_PUSHBUTTON, closeButton);
        if (settingsTab_ == 0) {
            auto appearance = control(L"COMBOBOX", L"外观", CBS_DROPDOWNLIST, 401);
            for (auto name : {L"跟随系统", L"深色", L"浅色"}) SendMessageW(appearance, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name));
            SendMessageW(appearance, CB_SETCURSEL, preferences_.appearance == "dark" ? 1 : (preferences_.appearance == "light" ? 2 : 0), 0);
            control(L"BUTTON", L"登录后静默启动青蛙导航", BS_AUTOCHECKBOX, 404);
            SendMessageW(controls_[404], BM_SETCHECK, !options_.isolated && loginStartupRegistered() ? BST_CHECKED : BST_UNCHECKED, 0);
            EnableWindow(controls_[404], !options_.isolated);
            control(L"BUTTON", L"打开 Windows 启动应用设置", BS_PUSHBUTTON, 405);
        } else if (settingsTab_ == 1) {
            control(L"BUTTON", hotkeyCapture_ ? L"请按下新快捷键…" : hotkeyName(preferences_.hotkey), BS_PUSHBUTTON, 410);
            control(L"BUTTON", L"恢复默认", BS_PUSHBUTTON, 411);
            control(L"BUTTON", L"启用全局快捷键", BS_AUTOCHECKBOX, 412); SendMessageW(controls_[412], BM_SETCHECK, preferences_.hotkey.enabled ? BST_CHECKED : BST_UNCHECKED, 0);
        } else if (settingsTab_ == 2) {
            control(L"BUTTON", L"启用屏幕触角", BS_AUTOCHECKBOX, 420); SendMessageW(controls_[420], BM_SETCHECK, preferences_.cornersEnabled ? BST_CHECKED : BST_UNCHECKED, 0);
            const wchar_t* cornerNames[]{L"左上角", L"右上角", L"左下角", L"右下角"};
            for (int i = 0; i < 4; ++i) { control(L"BUTTON", cornerNames[i], BS_AUTOCHECKBOX, 421 + i); SendMessageW(controls_[421 + i], BM_SETCHECK, preferences_.corners & (1u << i) ? BST_CHECKED : BST_UNCHECKED, 0); }
        } else if (settingsTab_ == 3) {
            control(L"EDIT", preferences_.dataDirectory.wstring(), ES_AUTOHSCROLL | ES_READONLY, 429);
            control(L"BUTTON", L"打开所在文件夹", BS_PUSHBUTTON, 430); control(L"BUTTON", L"选择目录…", BS_PUSHBUTTON, 431);
            control(L"BUTTON", L"导出 JSON…", BS_PUSHBUTTON, 432); control(L"BUTTON", L"恢复备份…", BS_PUSHBUTTON, 433); control(L"BUTTON", L"重试读取", BS_PUSHBUTTON, 434);
        } else {
            control(L"BUTTON", L"退出青蛙导航", BS_PUSHBUTTON, 440);
            control(L"STATIC", L"青蛙导航图标", SS_ICON | SS_REALSIZECONTROL, 441);
        }
    }
    const std::map<int, const wchar_t*> labels{{201,L"网址"},{202,L"标题"},{203,L"位置"},{204,L"新文件夹名称"},{211,L"文件夹名称"},{401,L"外观"},{429,L"数据目录"}};
    for (const auto& [id, name] : labels) if (controls_.contains(id)) accessibleName(controls_[id], name);
    layoutPanelControls(); syncAccessibility(); invalidate();
}
void Launcher::layoutPanelControls() {
    if (panel_ == Panel::none) return; auto r = panelBounds(); float x = r.x + 28, width = r.width - 56;
    if (panel_ == Panel::bookmark) {
        moveControl(inputUrl, {x, r.y + 105, width, 34}); moveControl(inputTitle, {x, r.y + 183, width, 34});
        moveControl(inputLocation, {x, r.y + 261, width, 250});
        moveControl(inputNewFolder, {x, r.y + 339, width, 34});
        auto it = controls_.find(inputNewFolder); if (it != controls_.end()) ShowWindow(it->second, draft_.location == "__new__" ? SW_SHOW : SW_HIDE);
    } else if (panel_ == Panel::rename) moveControl(inputRename, {x, r.y + 100, width, 34});
    if (panel_ != Panel::settings) {
        moveControl(cancelButton, {r.x + r.width - 224, r.y + r.height - 55, 88, 32}); moveControl(saveButton, {r.x + r.width - 124, r.y + r.height - 55, 96, 32}); return;
    }
    for (int i = 0; i < 5; ++i) moveControl(300 + i, {r.x + 18, r.y + 90 + 47.0f * i, 140, 36});
    moveControl(closeButton, {r.x + r.width - 106, r.y + r.height - 49, 82, 30});
    x = r.x + 200; width = r.width - 228;
    if (settingsTab_ == 0) {
        moveControl(401, {x + 160, r.y + 105, width - 160, 160}); moveControl(404, {x, r.y + 187, width, 32}); moveControl(405, {x, r.y + 277, width, 34});
    } else if (settingsTab_ == 1) {
        moveControl(412, {x, r.y + 104, width, 30}); moveControl(410, {x, r.y + 150, width - 122, 38}); moveControl(411, {x + width - 108, r.y + 150, 108, 38});
    } else if (settingsTab_ == 2) {
        moveControl(420, {x, r.y + 104, width, 30});
        for (int i = 0; i < 4; ++i) moveControl(421 + i, {x + (i % 2) * width / 2, r.y + 165 + (i / 2) * 58.0f, width / 2 - 10, 38});
    } else if (settingsTab_ == 3) {
        moveControl(429, {x, r.y + 113, width, 34}); moveControl(430, {x, r.y + 165, (width - 12) / 2, 34}); moveControl(431, {x + (width + 12) / 2, r.y + 165, (width - 12) / 2, 34});
        moveControl(432, {x + width - 150, r.y + 265, 150, 34}); moveControl(433, {x + width - 150, r.y + 319, 150, 34}); moveControl(434, {x, r.y + 384, 120, 32});
    } else {
        moveControl(440, {x, r.y + 316, 154, 36});
        moveControl(441, {x, r.y + 94, 68, 68});
        auto icon = LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(101), IMAGE_ICON,
                               static_cast<int>(68 * dpiScale_), static_cast<int>(68 * dpiScale_), LR_SHARED);
        SendMessageW(controls_[441], STM_SETICON, reinterpret_cast<WPARAM>(icon), 0);
    }
}
void Launcher::drawPanel() {
    auto r = panelBounds(); auto ink = color(theme_.dark ? 0xf2f2f2 : 0x202020), secondary = color(theme_.dark ? 0xaaaaaf : 0x66666b);
    if (theme_.highContrast) { auto c = GetSysColor(COLOR_WINDOWTEXT); ink = D2D1::ColorF(GetRValue(c) / 255.0f, GetGValue(c) / 255.0f, GetBValue(c) / 255.0f); secondary = ink; }
    rectangle({0, 0, view_.layout.width, view_.layout.height}, color(0x000000, theme_.highContrast ? 1 : .48f));
    auto surface = color(theme_.dark ? 0x242426 : 0xf3f3f3); if (theme_.highContrast) { auto c = GetSysColor(COLOR_WINDOW); surface = D2D1::ColorF(GetRValue(c) / 255.0f, GetGValue(c) / 255.0f, GetBValue(c) / 255.0f); }
    rectangle(r, surface, 8); rectangle(r, theme_.highContrast ? ink : color(theme_.dark ? 0xffffff : 0x000000, .12f), 8, true);
    if (panel_ == Panel::settings) {
        text(L"青蛙导航设置", {r.x + 25, r.y + 25, 150, 34}, 20, ink, false, true);
        rectangle({r.x + 176, r.y + 70, 1, r.height - 94}, color(theme_.dark ? 0xffffff : 0x000000, .09f));
        rectangle({r.x + 11, r.y + 98 + settingsTab_ * 47.0f, 3, 20}, color(theme_.dark ? 0x4cc2ff : 0x0067c0), 1);
        const wchar_t* names[]{L"常规", L"快捷键", L"屏幕触角", L"数据与备份", L"关于青蛙导航"};
        float x = r.x + 200, width = r.width - 228;
        text(names[settingsTab_], {x, r.y + 34, width, 36}, 24, ink, false, true);
        auto line = [&](const wchar_t* value, float y) { text(value, {x, r.y + y, width, 26}, 13, secondary); };
        if (settingsTab_ == 0) {
            text(L"外观", {x, r.y + 105, 140, 34}, 14, ink);
            line(options_.isolated ? L"隔离运行：登录启动设置不可修改。" : (loginStartupDisabled() ? L"Windows 已禁用此启动项，请在系统设置中开启。" : L"登录后驻留托盘，首次展开时创建界面。"), 231);
            line(L"打开网站、切换应用或点击空白处时收起。", 350);
            line(L"Alt + F4 收起；完全退出请使用托盘或关于页面。", 379);
        } else if (settingsTab_ == 1) {
            line(hotkeyCapture_ ? L"按下新的组合键，Esc 取消。" : L"点击组合键进行修改，冲突时保留原快捷键。", 209);
            line(L"Ctrl + N  添加书签        Ctrl + ,  打开设置", 281);
            line(L"Ctrl + F 或 /  搜索       Page Up / Down  翻页", 314);
            line(L"方向键选择 · Enter 打开 · Esc 逐层退出", 347);
        } else if (settingsTab_ == 2) {
            line(L"将鼠标移入所选屏幕角落即可展开启动台。", 303);
            line(L"离开后再次进入才会触发，拖动时暂停触发。", 337);
        } else if (settingsTab_ == 3) {
            line(L"书签数据目录", 82);
            line(L"可使用坚果云等工具同步；图标与偏好保留在本机。", 219);
            text(L"另存备份", {x, r.y + 265, 160, 34}, 14, ink); text(L"完整恢复", {x, r.y + 319, 160, 34}, 14, ink);
            text(L"恢复会替换全部书签和文件夹。", {x + 136, r.y + 384, width - 136, 32}, 12, secondary);
        } else {
            text(L"青蛙导航  1.0.0", {x, r.y + 183, width, 36}, 22, ink, false, true);
            line(L"Windows 11 x64 · 本地书签启动台", 230); line(L"书签备份与 macOS 客户端互通。", 263);
        }
    } else {
        text(panel_ == Panel::rename ? L"重命名文件夹" : (draft_.id.empty() ? L"添加书签" : L"编辑书签"), {r.x + 28, r.y + 24, r.width - 56, 34}, 24, ink, false, true);
        auto label = [&](const wchar_t* value, float y) { text(value, {r.x + 28, r.y + y, r.width - 56, 24}, 13, ink); };
        if (panel_ == Panel::rename) label(L"文件夹名称", 71);
        else { label(L"网址", 76); label(L"标题", 154); label(L"位置", 232); if (draft_.location == "__new__") label(L"新文件夹名称", 310); }
    }
}
void Launcher::readDraft() {
    if (panel_ != Panel::bookmark || !controls_.contains(inputUrl)) return;
    draft_.url = utf8(windowText(controls_[inputUrl])); draft_.title = utf8(windowText(controls_[inputTitle])); draft_.newFolder = utf8(windowText(controls_[inputNewFolder]));
    auto index = SendMessageW(controls_[inputLocation], CB_GETCURSEL, 0, 0); if (index >= 0 && static_cast<size_t>(index) < locationChoices_.size()) draft_.location = locationChoices_[index];
}
void Launcher::edit(const std::string& id) {
    if (panel_ != Panel::none) return;
    cancelDrag(); draft_ = {}; draft_.expected = snapshot_.bytes; draft_.location = view_.inFolder() ? *view_.folder : "";
    if (!id.empty()) { auto b = snapshot_.document.bookmark(id); if (!b) return; draft_.id = id; draft_.title = b->title; draft_.url = b->url; draft_.location = b->groupId.value_or(""); }
    panel_ = Panel::bookmark; createPanelControls(); SetFocus(controls_[inputUrl]); SendMessageW(controls_[inputUrl], EM_SETSEL, 0, -1); animate();
}
void Launcher::rename(const std::string& id) {
    if (panel_ != Panel::none || !snapshot_.document.group(id)) return;
    cancelDrag(); renameId_ = id; renameExpected_ = snapshot_.bytes; panel_ = Panel::rename;
    createPanelControls(); SetFocus(controls_[inputRename]); SendMessageW(controls_[inputRename], EM_SETSEL, 0, -1);
}
void Launcher::settings() {
    if (panel_ != Panel::none) return; cancelDrag(); panel_ = Panel::settings; settingsTab_ = 0; createPanelControls(); SetFocus(controls_[300]); animate();
}
void Launcher::closePanel(bool discard) {
    if (panel_ == Panel::bookmark && !discard) readDraft();
    destroyPanelControls(); panel_ = Panel::none; hotkeyCapture_ = false;
    EnableWindow(search_, TRUE); EnableWindow(settingsButton_, TRUE); EnableWindow(addButton_, TRUE); SetFocus(search_);
    ShowWindow(search_, SW_SHOW); ShowWindow(settingsButton_, SW_SHOW); ShowWindow(addButton_, SW_SHOW); SetFocus(search_);
    if (!statusPersistent_) status_.clear(); updateLayout(); animate();
}
void Launcher::saveDraft() {
    if (panel_ != Panel::bookmark && panel_ != Panel::rename) return;
    if (busy_) { notify("正在保存，请稍后。"); return; }
    if (panel_ == Panel::rename) {
        auto name = utf8(windowText(controls_.at(inputRename))), id = renameId_;
        mutate([id, name](Document& data) { data.renameGroup(id, name); }, [this] { closePanel(); }, renameExpected_); return;
    }
    readDraft(); auto draft = draft_; Location location;
    if (!draft.location.empty() && draft.location != "__new__") location = draft.location;
    if (draft.location == "__new__") require(!trim(draft.newFolder).empty(), "请输入新文件夹名称。");
    auto savedId = std::make_shared<std::string>();
    mutate([=](Document& data) { *savedId = data.upsert(draft.id, draft.title, draft.url, location, draft.location == "__new__" ? draft.newFolder : ""); },
        [this, savedId] { closePanel(); SetWindowTextW(search_, L""); view_.reveal(snapshot_.document, *savedId); updateLayout(); }, draft.expected);
}
void Launcher::refreshSettings() {
    if (panel_ != Panel::settings) return;
    createPanelControls(); if (settingsTab_ == 1) SetFocus(controls_[410]); else SetFocus(controls_[300 + settingsTab_]);
}
void Launcher::updatePreferences(Preferences next) {
    auto old = preferences_;
    try { hotkey_.set(controller_, next.hotkey); corners_.configure(controller_, next.cornersEnabled, next.corners); next.save(options_); }
    catch (...) {
        try { hotkey_.set(controller_, old.hotkey); corners_.configure(controller_, old.cornersEnabled, old.corners); } catch (const std::exception&) {}
        throw;
    }
    preferences_ = std::move(next); updateTheme(); invalidate();
}
void Launcher::panelCommand(int id, int notification) {
    if (id == inputLocation && notification == CBN_SELCHANGE) { readDraft(); layoutPanelControls(); invalidate(); return; }
    if (id == cancelButton || id == closeButton) { if (!busy_) closePanel(); return; }
    if (id == saveButton) { saveDraft(); return; }
    if (id >= 300 && id <= 304) { hotkeyCapture_ = false; settingsTab_ = id - 300; status_.clear(); statusPersistent_ = false; refreshSettings(); return; }
    if (panel_ != Panel::settings) return;
    if (id == 401 && notification == CBN_SELCHANGE) {
        int index = static_cast<int>(SendMessageW(controls_[401], CB_GETCURSEL, 0, 0)); auto prefs = preferences_; prefs.appearance = index == 1 ? "dark" : (index == 2 ? "light" : "system"); updatePreferences(prefs);
    } else if (id == 404) {
        require(!options_.isolated, "隔离运行不修改登录启动。");
        try { setLoginStartup(SendMessageW(controls_[404], BM_GETCHECK, 0, 0) == BST_CHECKED); }
        catch (...) { SendMessageW(controls_[404], BM_SETCHECK, loginStartupRegistered() ? BST_CHECKED : BST_UNCHECKED, 0); throw; }
        refreshSettings(); notify(loginStartupRegistered() ? "已启用登录启动。" : "已关闭登录启动。");
    } else if (id == 405) {
        if (reinterpret_cast<INT_PTR>(ShellExecuteW(window_, L"open", L"ms-settings:startupapps", nullptr, nullptr, SW_SHOWNORMAL)) <= 32) notify("无法打开 Windows 启动应用设置。", true);
    } else if (id == 410) { hotkeyCapture_ = true; refreshSettings(); }
    else if (id == 411 || id == 412) {
        auto prefs = preferences_; if (id == 411) prefs.hotkey = {}; else prefs.hotkey.enabled = SendMessageW(controls_[412], BM_GETCHECK, 0, 0) == BST_CHECKED;
        try { updatePreferences(prefs); } catch (...) { refreshSettings(); throw; } refreshSettings();
    } else if (id >= 420 && id <= 424) {
        auto prefs = preferences_; prefs.cornersEnabled = SendMessageW(controls_[420], BM_GETCHECK, 0, 0) == BST_CHECKED; prefs.corners = 0;
        for (int i = 0; i < 4; ++i) if (SendMessageW(controls_[421 + i], BM_GETCHECK, 0, 0) == BST_CHECKED) prefs.corners |= 1u << i;
        try { updatePreferences(prefs); } catch (...) { refreshSettings(); throw; }
    } else if (id >= 430 && id <= 434) dataAction(id);
    else if (id == 440) quit();
}
void Launcher::dataAction(int action) {
    require(!busy_, "正在处理数据，请稍后重试。");
    if (action == 430) {
        auto result = ShellExecuteW(window_, L"open", preferences_.dataDirectory.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        require(reinterpret_cast<INT_PTR>(result) > 32, "数据目录不可用，无法在资源管理器中打开。"); return;
    }
    if (action == 434) { reload(); return; }
    if (action != 431) require(loaded_, "请先成功读取书签，再导出或恢复备份。");
    systemPanel_ = true; corners_.suppress(true);
    std::optional<fs::path> selected;
    try { selected = chooseFile(window_, action == 432, action == 431); } catch (...) { systemPanel_ = false; corners_.suppress(false); throw; }
    systemPanel_ = false; corners_.suppress(false); if (!selected) return;
    auto path = *selected, oldDirectory = preferences_.dataDirectory; auto document = snapshot_.document; auto expected = snapshot_.bytes;
    busy_ = true;
    storageQueue_->post([this, path, action, oldDirectory, document = std::move(document), expected] {
        try {
            if (action == 432) {
                storage_.backup(path, document); dispatch([this] { busy_ = false; notify("备份已导出。"); });
            } else if (action == 433) {
                auto candidate = Document::decode(readFile(path));
                dispatch([this, candidate = std::move(candidate), expected] {
                    busy_ = false; systemPanel_ = true; corners_.suppress(true);
                    auto prompt = L"此备份包含 " + std::to_wstring(candidate.bookmarks.size()) + L" 条书签和 " + std::to_wstring(candidate.groups.size()) + L" 个文件夹。\n\n恢复将整体替换当前数据，确认继续？";
                    int answer = MessageBoxW(window_, prompt.c_str(), L"恢复备份", MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2); systemPanel_ = false; corners_.suppress(false);
                    if (answer == IDOK) mutate([candidate](Document& current) { current = candidate; }, [this] { view_.folder.reset(); view_.rootPage = 0; SetWindowTextW(search_, L""); updateLayout(); notify("备份已完整恢复。"); }, expected);
                });
            } else {
                auto next = storage_.open(path, false, document);
                dispatch([this, next = std::move(next), oldDirectory]() mutable {
                    try {
                        auto prefs = preferences_; prefs.dataDirectory = next.directory; prefs.save(options_); preferences_ = prefs;
                        busy_ = false; view_.folder.reset(); view_.rootPage = 0; applySnapshot(std::move(next)); refreshSettings(); notify("已切换数据目录。");
                    } catch (const std::exception& error) {
                        storageQueue_->post([this, oldDirectory, message = std::string(error.what())] {
                            try { auto restored = storage_.open(oldDirectory, false, {}, false); dispatch([this, restored = std::move(restored), message]() mutable { busy_ = false; applySnapshot(std::move(restored)); notify(message + " 已恢复原数据目录。", true); }); }
                            catch (const std::exception& restoreError) { dispatch([this, message, detail = std::string(restoreError.what())] { busy_ = false; loaded_ = false; notify(message + " 原目录恢复失败：" + detail, true); }); }
                        });
                    }
                });
            }
        } catch (const std::exception& error) { dispatch([this, message = std::string(error.what())] { busy_ = false; notify(message + " 原数据保持不变。", true); }); }
    });
}
}
