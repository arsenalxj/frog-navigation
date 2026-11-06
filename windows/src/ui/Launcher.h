#pragma once
#include "platform/Integration.h"
#include "Accessibility.h"
#include <d2d1.h>
#include <dwrite.h>
#include <map>
#include <set>

#include <string_view>
#include <iterator>
#include <cstdio>
namespace frog {
enum class TerminalBuffer { none, settings, help, log, job, calc };
struct Rect {
    float x, y, width, height;
    bool contains(float px, float py) const { return px >= x && py >= y && px < x + width && py < y + height; }
};
enum class TerminalInput { none, command, search, prompt, calc };
struct TerminalRow {
    std::string id, title, detail, groupName;
    Location group;
    bool folder = false, expanded = false;
    int depth = 0;
    std::wstring initial;
    UINT32 iconColor = 0x0d5e3a;
};
struct TerminalLine { std::string time, text; UINT32 color = 0x3b3a3e; };
struct TerminalChoice { std::string id, label, detail; };
struct TerminalPrompt {
    std::string command, field, hint, error;
    int step = 0, total = 0, selected = 0;
    bool acceptsText = true;
    std::vector<TerminalChoice> choices;
};
struct Draft {
    std::string id, title, url, location = "__root__", folder, path, expected;
    bool isFolder = false, titleInitialized = false;
};
struct CalcEntry { std::string time, expression, value; };
class Launcher {
public:
    Launcher(Options options, Instance& instance);
    ~Launcher();
    int run();
    HWND window() const { return window_; }
private:
    static LRESULT CALLBACK controllerProc(HWND, UINT, WPARAM, LPARAM);
    static LRESULT CALLBACK windowProc(HWND, UINT, WPARAM, LPARAM);
    static LRESULT CALLBACK controlProc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);
    LRESULT controllerMessage(UINT, WPARAM, LPARAM);
    LRESULT message(UINT, WPARAM, LPARAM);
    bool keyboard(WPARAM key, bool control, bool shift);
    bool character(wchar_t value);
    void createWindow();
    void show(bool settings = false);
    void hide();
    void quit();
    void place(bool mouseMonitor);
    void updateLayout();
    void layoutInput();
    void paint();
    void ensureRenderer();
    void releaseRenderer();
    void invalidate();
    void text(const std::wstring&, Rect, float, UINT32, bool center = false, bool bold = false);
    void rectangle(Rect, UINT32, float radius = 0, bool outline = false);
    void drawRows();
    void drawBuffer();
    void drawOutput();
    void drawChrome();
    void dispatch(std::function<void()>);
    void loadInitial();
    void reload();
    void applySnapshot(Snapshot);
    void mutate(std::function<void(Document&)>, std::function<void()> success = {}, std::string expected = {});
    void notify(const std::string&, bool error = false);
    void appendLog(const std::string&, UINT32 color = 0x126e82);
    void tray(bool add);
    void trayMenu();
    void menu(POINT);
    void activate();
    void open(const std::string&);
    void copySelection();
    void rebuildItems(const std::string& selected = {});
    void clampSelection();
    const TerminalRow* selectedRow() const;
    void updateHover(float, float);
    void moveCursor(int);
    void scroll(int);
    void toggleFolder(const std::string&);
    void toggleAll();
    void persistExpanded();
    void reorder(int);
    void escape();
    int hitRow(float, float) const;
    void click(float, float, bool activate);
    void dragMove(float, float);
    void dragEnd(float, float);
    void cancelDrag();
    void syncAccessibility();
    void accessibleAction(int, bool);
    void setInput(TerminalInput, const std::string& = {});
    void inputChanged();
    bool textInputActive() const;
    void startSearch();
    void submitInput();
    void runCommand(const std::string&);
    void completeCommand(bool backward);
    void recallHistory(int);
    void openBuffer(TerminalBuffer);
    void refreshBuffer();
    void beginPrompt(const std::string&, const std::string&, const std::string&, int step = 0, int total = 0, bool acceptsText = true);
    void beginAction(const std::string&, bool urlFirst = false);
    void finishPrompt();
    void captureDraft();
    void previousPrompt();
    void switchEditField();
    void showLocation();
    void refreshChoices(bool filter);
    void chooseOption(int);
    void cycleChoice(int);
    void submitPrompt();
    void saveBookmark();
    void confirmDelete();
    void beginFilePrompt(const std::string&, const std::string&);
    fs::path resolvedPath(const std::string&) const;
    void runFileOperation(const std::string&, const fs::path&);
    void runEdgeImport(const fs::path&);
    void runSetting(const std::string&);
    void updatePreferences(const Preferences&);
    void openCalc();
    void submitCalc();
    void browseCalc(int);
    void selectCalc(int);
    void copyCalc();
    void updateCalcPreview();
    std::string promptLabel() const;
    std::string inputHint() const;
    std::string modeLabel() const;
    std::string shortcuts() const;

    Options options_; Instance& instance_; Preferences preferences_; Diagnostics diagnostics_;
    HWND controller_{}, window_{}, search_{};
    HFONT font_{}; HBRUSH editBrush_{};
    UINT taskbarCreated_{}; GlobalHotKey hotkey_; Corners corners_;
    std::unique_ptr<SerialQueue> storageQueue_; Storage storage_; DirectoryWatcher watcher_;
    Snapshot snapshot_;
    std::vector<TerminalRow> rows_;
    std::set<std::string> expanded_;
    int selection_ = 0, scroll_ = 0, bufferOffset_ = 0, wheel_ = 0;
    float scale_ = 1, originX_ = 0, originY_ = 0, inputX_ = 58;
    int fontHeight_ = 0;
    bool loaded_ = false, busy_ = false, reloading_ = false, reloadPending_ = false, visible_ = false, quitting_ = false;
    bool inMenu_ = false, composing_ = false, changingInput_ = false, organizing_ = false;
    bool firstShow_ = true, paintPending_ = false;
    double showStart_ = 0;
    std::string query_, inputText_, issue_, hotkeyError_;
    std::map<std::string, std::string> settingErrors_;
    TerminalBuffer buffer_ = TerminalBuffer::none;
    TerminalInput input_ = TerminalInput::none;
    std::optional<TerminalPrompt> prompt_;
    Draft draft_;
    std::vector<TerminalLine> logs_, bufferLines_, jobLines_;
    std::vector<TerminalChoice> commandHints_, helpCommands_;
    HWND tooltip_{};
    std::wstring tooltipText_;
    int hoverBuffer_ = -1;
    double cornerFlashUntil_ = 0;
    std::string jobTitle_, jobStatus_;
    std::vector<std::string> history_;
    int historyIndex_ = -1;
    std::string historyDraft_, completionPrefix_, lastCompletion_;
    uint64_t choiceGeneration_ = 0;
    std::string calcExpression_, calcPreview_, calcError_, calcFeedback_;
    std::vector<CalcEntry> calcHistory_;
    int calcHistoryIndex_ = -1;
    DWORD savedSelectionStart_ = 0, savedSelectionEnd_ = 0;
    std::string dragSource_, dragExpected_;
    float dragX_ = 0, dragY_ = 0;
    int dragTarget_ = -1;
    bool dragging_ = false;
    bool dragBefore_ = true, dragMerge_ = false, mergeReady_ = false;
    float dragCurrentX_ = 0, dragCurrentY_ = 0;
    double dragHoverSince_ = 0;
    ComPtr<ID2D1Factory> d2d_; ComPtr<IDWriteFactory> dwrite_;
    ComPtr<ID2D1HwndRenderTarget> target_; ComPtr<ID2D1SolidColorBrush> brush_;
    std::map<std::pair<int, bool>, ComPtr<IDWriteTextFormat>> formats_;
    std::shared_ptr<AccessibleState> accessibility_ = std::make_shared<AccessibleState>();
    ComPtr<IRawElementProviderSimple> provider_;
    std::map<int, std::string> accessibleActions_;
    std::map<std::string, int> accessibleTokens_;
    int nextToken_ = 10;
};
}
