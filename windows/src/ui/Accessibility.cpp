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
        case UIA_AutomationIdPropertyId: string(token_ ? L"Frog.Item." + std::to_wstring(token_) : L"Frog.Terminal"); break;
        case UIA_ControlTypePropertyId: value->vt = VT_I4; value->lVal = token_ ? UIA_ButtonControlTypeId : UIA_PaneControlTypeId; break;
        case UIA_HelpTextPropertyId: string(node ? node->help : L"方向键或 j/k 选择，Enter 打开，e 编辑，D 删除，冒号输入命令。"); break;
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
}
