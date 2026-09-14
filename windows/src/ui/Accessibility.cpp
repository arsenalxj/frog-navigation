#include "Launcher.h"
#include <atomic>
#include <algorithm>

namespace frog {
namespace {
class Provider final : public IRawElementProviderSimple, public IRawElementProviderFragment, public IRawElementProviderFragmentRoot, public IInvokeProvider, public ISelectionItemProvider, public ISelectionProvider {
public:
    explicit Provider(std::shared_ptr<AccessibleState> state, int token = 0) : state_(std::move(state)), token_(token) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (!out) return E_POINTER; *out = nullptr;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IRawElementProviderSimple)) *out = static_cast<IRawElementProviderSimple*>(this);
        else if (iid == __uuidof(IRawElementProviderFragment)) *out = static_cast<IRawElementProviderFragment*>(this);
        else if (iid == __uuidof(IRawElementProviderFragmentRoot) && token_ == 0) *out = static_cast<IRawElementProviderFragmentRoot*>(this);
        else if (iid == __uuidof(IInvokeProvider) && token_) *out = static_cast<IInvokeProvider*>(this);
        else if (iid == __uuidof(ISelectionItemProvider) && token_) *out = static_cast<ISelectionItemProvider*>(this);
        else if (iid == __uuidof(ISelectionProvider) && !token_) *out = static_cast<ISelectionProvider*>(this);
        if (!*out) return E_NOINTERFACE; AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override { auto count = --references_; if (!count) delete this; return count; }
    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions* value) override { if (!value) return E_POINTER; *value = ProviderOptions_ServerSideProvider; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID id, IUnknown** value) override {
        if (!value) return E_POINTER; *value = nullptr;
        if (token_ && id == UIA_InvokePatternId) { *value = static_cast<IInvokeProvider*>(this); AddRef(); }
        if (token_ && id == UIA_SelectionItemPatternId) { *value = static_cast<ISelectionItemProvider*>(this); AddRef(); }
        if (!token_ && id == UIA_SelectionPatternId) { *value = static_cast<ISelectionProvider*>(this); AddRef(); }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID id, VARIANT* value) override {
        if (!value) return E_POINTER; VariantInit(value); std::lock_guard lock(state_->mutex);
        if (!state_->window) return UIA_E_ELEMENTNOTAVAILABLE;
        auto node = find(); if (token_ && !node) return UIA_E_ELEMENTNOTAVAILABLE;
        auto string = [&](const std::wstring& text) { value->vt = VT_BSTR; value->bstrVal = SysAllocString(text.c_str()); };
        auto boolean = [&](bool b) { value->vt = VT_BOOL; value->boolVal = b ? VARIANT_TRUE : VARIANT_FALSE; };
        switch (id) {
        case UIA_NamePropertyId: string(node ? node->name : L"青蛙导航书签启动台"); break;
        case UIA_AutomationIdPropertyId: string(token_ ? L"Frog.Item." + std::to_wstring(token_) : L"Frog.Grid"); break;
        case UIA_ControlTypePropertyId: value->vt = VT_I4; value->lVal = token_ ? UIA_ButtonControlTypeId : UIA_PaneControlTypeId; break;
        case UIA_HelpTextPropertyId: string(node ? node->help : L"方向键选择，Enter 打开，F2 编辑，Delete 删除。"); break;
        case UIA_IsKeyboardFocusablePropertyId: case UIA_IsControlElementPropertyId: case UIA_IsContentElementPropertyId: boolean(true); break;
        case UIA_IsEnabledPropertyId: boolean(!node || node->enabled); break;
        case UIA_HasKeyboardFocusPropertyId: boolean(state_->focus == token_); break;
        case UIA_IsOffscreenPropertyId: boolean(!IsWindowVisible(state_->window)); break;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple** value) override {
        if (!value) return E_POINTER; *value = nullptr;
        std::lock_guard lock(state_->mutex); if (!state_->window) return UIA_E_ELEMENTNOTAVAILABLE;
        return token_ ? S_OK : UiaHostProviderFromHwnd(state_->window, value);
    }
    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction, IRawElementProviderFragment** value) override {
        if (!value) return E_POINTER; *value = nullptr; std::lock_guard lock(state_->mutex);
        if (!state_->window) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!token_) {
            if (state_->nodes.empty()) return S_OK;
            if (direction == NavigateDirection_FirstChild) *value = child(state_->nodes.front().token);
            if (direction == NavigateDirection_LastChild) *value = child(state_->nodes.back().token);
        } else {
            if (direction == NavigateDirection_Parent) *value = child(0);
            auto it = std::find_if(state_->nodes.begin(), state_->nodes.end(), [&](const auto& node) { return node.token == token_; });
            if (it == state_->nodes.end()) return UIA_E_ELEMENTNOTAVAILABLE;
            if (direction == NavigateDirection_NextSibling && std::next(it) != state_->nodes.end()) *value = child(std::next(it)->token);
            if (direction == NavigateDirection_PreviousSibling && it != state_->nodes.begin()) *value = child(std::prev(it)->token);
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY** value) override {
        if (!value) return E_POINTER; *value = nullptr; if (!token_) return S_OK;
        int ids[]{UiaAppendRuntimeId, token_}; *value = SafeArrayCreateVector(VT_I4, 0, 2);
        for (LONG i = 0; i < 2; ++i) SafeArrayPutElement(*value, &i, &ids[i]); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect* value) override {
        if (!value) return E_POINTER; std::lock_guard lock(state_->mutex);
        if (!state_->window) return UIA_E_ELEMENTNOTAVAILABLE;
        RECT rect{};
        if (token_) { auto node = find(); if (!node) return UIA_E_ELEMENTNOTAVAILABLE; rect = node->bounds; } else GetWindowRect(state_->window, &rect);
        *value = {static_cast<double>(rect.left), static_cast<double>(rect.top), static_cast<double>(rect.right - rect.left), static_cast<double>(rect.bottom - rect.top)}; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY** value) override { if (!value) return E_POINTER; *value = nullptr; return S_OK; }
    HRESULT STDMETHODCALLTYPE SetFocus() override { return invoke(true); }
    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot** value) override { if (!value) return E_POINTER; *value = new Provider(state_); return S_OK; }
    HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double x, double y, IRawElementProviderFragment** value) override {
        if (!value) return E_POINTER; *value = nullptr; std::lock_guard lock(state_->mutex);
        if (!state_->window) return UIA_E_ELEMENTNOTAVAILABLE;
        POINT point{static_cast<LONG>(x), static_cast<LONG>(y)};
        for (const auto& node : state_->nodes) if (PtInRect(&node.bounds, point)) { *value = child(node.token); return S_OK; }
        *value = child(0); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment** value) override {
        if (!value) return E_POINTER; std::lock_guard lock(state_->mutex); if (!state_->window) return UIA_E_ELEMENTNOTAVAILABLE; *value = child(state_->focus); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Invoke() override { return invoke(false); }
    HRESULT STDMETHODCALLTYPE Select() override { return invoke(true); }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return invoke(true); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return UIA_E_INVALIDOPERATION; }
    HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL* value) override { if (!value) return E_POINTER; std::lock_guard lock(state_->mutex); auto node = find(); if (!node) return UIA_E_ELEMENTNOTAVAILABLE; *value = node->selected; return S_OK; }
    HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple** value) override { if (!value) return E_POINTER; *value = new Provider(state_); return S_OK; }
    HRESULT STDMETHODCALLTYPE GetSelection(SAFEARRAY** value) override {
        if (!value) return E_POINTER; std::lock_guard lock(state_->mutex); if (!state_->window) return UIA_E_ELEMENTNOTAVAILABLE;
        int selected = 0; for (const auto& node : state_->nodes) if (node.selected) { selected = node.token; break; }
        *value = SafeArrayCreateVector(VT_UNKNOWN, 0, selected ? 1 : 0);
        if (selected) { auto* provider = static_cast<IRawElementProviderSimple*>(new Provider(state_, selected)); LONG index = 0; SafeArrayPutElement(*value, &index, provider); provider->Release(); }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_CanSelectMultiple(BOOL* value) override { if (!value) return E_POINTER; *value = FALSE; return S_OK; }
    HRESULT STDMETHODCALLTYPE get_IsSelectionRequired(BOOL* value) override { if (!value) return E_POINTER; *value = FALSE; return S_OK; }
private:
    AccessibleNode* find() { for (auto& node : state_->nodes) if (node.token == token_) return &node; return nullptr; }
    IRawElementProviderFragment* child(int token) { return static_cast<IRawElementProviderFragment*>(new Provider(state_, token)); }
    HRESULT invoke(bool focusOnly) {
        std::lock_guard lock(state_->mutex); if (!state_->window || (token_ && !find())) return UIA_E_ELEMENTNOTAVAILABLE;
        auto node = find(); if (node && !node->enabled) return UIA_E_ELEMENTNOTENABLED;
        return PostMessageW(state_->window, wmAccessibleInvoke, token_, focusOnly ? 1 : 0) ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
    }
    std::atomic<ULONG> references_{1}; std::shared_ptr<AccessibleState> state_; int token_{};
};
}
IRawElementProviderSimple* createAccessibility(const std::shared_ptr<AccessibleState>& state) { return new Provider(state); }
void Launcher::syncAccessibility() {
    if (!window_) return;
    std::vector<AccessibleNode> nodes; accessibleActions_.clear(); int focus = 0;
    auto add = [&](const std::string& action, const std::wstring& name, Rect rect, bool selected, const std::wstring& help) {
        if (!accessibleTokens_.contains(action)) accessibleTokens_[action] = nextToken_++;
        int token = accessibleTokens_[action]; accessibleActions_[token] = action;
        POINT origin{}; ClientToScreen(window_, &origin);
        RECT bounds{origin.x + static_cast<LONG>(rect.x * dpiScale_), origin.y + static_cast<LONG>(rect.y * dpiScale_), origin.x + static_cast<LONG>((rect.x + rect.width) * dpiScale_), origin.y + static_cast<LONG>((rect.y + rect.height) * dpiScale_)};
        nodes.push_back({token, name, help, bounds, selected, true, false}); if (selected) focus = token;
    };
    if (panel_ == Panel::none) {
        for (size_t i = 0; i < visibleItems_.size(); ++i) {
            auto& item = visibleItems_[i]; std::wstring help = item.folder ? L"文件夹，按 Enter 展开。" : L"书签，按 Enter 打开；F2 编辑；Delete 删除。";
            if (auto b = snapshot_.document.bookmark(item.id)) { help += wide(b->url); if (b->groupId) if (auto g = snapshot_.document.group(*b->groupId)) help += L"，所属文件夹：" + wide(g->name); }
            add(item.id, wide(item.title), view_.layout.tile(static_cast<int>(i), view_.inFolder()), view_.selection == static_cast<int>(i), help);
        }
        if (view_.pageCount(snapshot_.document) > 1) { add("__previous__", L"上一页", {20, view_.layout.height / 2 - 24, 32, 48}, false, L"Page Up"); add("__next__", L"下一页", {view_.layout.width - 52, view_.layout.height / 2 - 24, 32, 48}, false, L"Page Down"); }
        if (view_.inFolder()) add("__back__", L"返回根目录", view_.layout.folderBounds(), false, L"Esc 返回");
    }
    bool changed = false, focusChanged = false;
    { std::lock_guard lock(accessibility_->mutex);
      focusChanged = accessibility_->focus != focus;
      changed = accessibility_->nodes.size() != nodes.size();
      if (!changed) for (size_t i = 0; i < nodes.size(); ++i) if (nodes[i].token != accessibility_->nodes[i].token || nodes[i].name != accessibility_->nodes[i].name || !EqualRect(&nodes[i].bounds, &accessibility_->nodes[i].bounds)) { changed = true; break; }
      accessibility_->window = window_; accessibility_->nodes = std::move(nodes); accessibility_->focus = focus; }
    if (changed && provider_) UiaRaiseStructureChangedEvent(provider_.Get(), StructureChangeType_ChildrenInvalidated, nullptr, 0);
    if (focusChanged && focus && provider_) { auto* item = static_cast<IRawElementProviderSimple*>(new Provider(accessibility_, focus)); UiaRaiseAutomationEvent(item, UIA_AutomationFocusChangedEventId); item->Release(); }
}
void Launcher::accessibleAction(int token, bool focusOnly) {
    if (panel_ != Panel::none || !visible_) return;
    auto it = accessibleActions_.find(token); if (it == accessibleActions_.end()) return; auto action = it->second;
    if (action == "__previous__") turn(-1); else if (action == "__next__") turn(1); else if (action == "__back__") { view_.folder.reset(); updateLayout(); }
    else {
        for (size_t i = 0; i < visibleItems_.size(); ++i) if (visibleItems_[i].id == action) view_.selection = static_cast<int>(i);
        SetFocus(window_); syncAccessibility(); if (!focusOnly) activate(action); else invalidate();
    }
}
}
