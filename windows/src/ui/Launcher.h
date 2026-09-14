#pragma once
#include "core/State.h"
#include "platform/Integration.h"
#include "platform/Images.h"
#include "Accessibility.h"
#include <d2d1.h>
#include <dwrite.h>
#include <map>
#include <unordered_map>

namespace frog {
enum class Panel { none, bookmark, rename, settings };
struct Draft { std::string id, title, url, location, newFolder, expected; };
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
    void createWindow();
    void show(bool settings = false);
    void hide();
    void quit();
    void place(bool mouseMonitor);
    void updateLayout();
    void paint();
    void ensureRenderer();
    void releaseRenderer();
    void animate(int direction = 0);
    void invalidate();
    void text(const std::wstring& value, Rect rect, float size, D2D1_COLOR_F color, bool center = false, bool bold = false, bool wrap = false);
    void rectangle(Rect rect, D2D1_COLOR_F color, float radius = 0, bool outline = false);
    void drawTile(const Item& item, Rect rect, int index, float opacity = 1);
    void drawIcon(const Bookmark& bookmark, Rect rect, float opacity = 1);
    void drawPanel();
    void receivedImage(std::string url, std::shared_ptr<Pixels> pixels);
    void requestImages();
    void dispatch(std::function<void()> action);
    void loadInitial();
    void reload();
    void applySnapshot(Snapshot snapshot);
    void mutate(std::function<void(Document&)> mutation, std::function<void()> success = {}, std::string expected = {}, std::function<void()> failure = {});
    void notify(const std::string& value, bool persistent = false);
    void tray(bool add);
    void trayMenu();
    void menu(const std::string& id, POINT point);
    void activate(const std::string& id);
    void open(const std::string& url);
    void remove(const std::string& id);
    void turn(int delta);
    void openFolder(const std::string& id);
    void escape();
    void pointerDown(float x, float y);
    void pointerMove(float x, float y);
    void pointerUp(float x, float y);
    void cancelDrag();
    void dragTick();
    int hitTile(float x, float y) const;
    void syncAccessibility();
    void accessibleAction(int token, bool focusOnly);
    void edit(const std::string& id = {});
    void rename(const std::string& id);
    void settings();
    void closePanel(bool discard = true);
    void createPanelControls();
    void destroyPanelControls();
    void layoutPanelControls();
    void panelCommand(int id, int notification);
    void saveDraft();
    void readDraft();
    void refreshSettings();
    void dataAction(int action);
    void updatePreferences(Preferences preferences);
    HWND control(const wchar_t* type, const std::wstring& text, DWORD style, int id);
    void moveControl(int id, Rect rect);
    Rect panelBounds() const;
    void updateTheme();
    void focusSearch();
    void savePage();

    Options options_; Instance& instance_; Preferences preferences_; Theme theme_; Diagnostics diagnostics_;
    HWND controller_{}, window_{}, search_{}, settingsButton_{}, addButton_{};
    HFONT font_{}; HBRUSH editBrush_{};
    UINT taskbarCreated_{}; GlobalHotKey hotkey_; Corners corners_;
    std::unique_ptr<SerialQueue> storageQueue_; Storage storage_; DirectoryWatcher watcher_; std::unique_ptr<Images> images_;
    fs::path cacheDirectory_;
    Snapshot snapshot_; ViewState view_; DragState drag_;
    std::vector<Item> visibleItems_;
    std::string dragExpected_;
    bool loaded_ = false, busy_ = false, reloadPending_ = false, visible_ = false, quitting_ = false;
    bool systemPanel_ = false, inMenu_ = false, composing_ = false, hotkeyCapture_ = false;
    int hover_ = -1, wheel_ = 0, animationDirection_ = 0;
    float dpiScale_ = 1;
    double animationStart_ = 0, showStart_ = 0;
    bool paintPending_ = false, firstShow_ = true;
    std::string status_; bool statusPersistent_ = false;
    Panel panel_ = Panel::none; Draft draft_; std::string renameId_, renameExpected_;
    int settingsTab_ = 0;
    std::map<int, HWND> controls_;
    std::vector<std::string> locationChoices_;
    ComPtr<ID2D1Factory> d2d_; ComPtr<IDWriteFactory> dwrite_; ComPtr<ID2D1HwndRenderTarget> target_; ComPtr<ID2D1SolidColorBrush> brush_;
    std::map<std::pair<int, bool>, ComPtr<IDWriteTextFormat>> formats_;
    std::unordered_map<std::string, ComPtr<ID2D1Bitmap>> bitmaps_;
    ComPtr<ID2D1Bitmap> wallpaper_;
    std::set<std::string> requestedIcons_;
    std::shared_ptr<AccessibleState> accessibility_ = std::make_shared<AccessibleState>();
    ComPtr<IRawElementProviderSimple> provider_;
    std::map<int, std::string> accessibleActions_;
    std::map<std::string, int> accessibleTokens_; int nextToken_ = 10;
};
}
