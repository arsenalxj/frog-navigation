#pragma once
#include "core/Util.h"
#include <UIAutomation.h>
#include <mutex>
#include <memory>

namespace frog {
struct AccessibleNode { int token{}; std::wstring name, help; RECT bounds{}; bool selected = false, enabled = true, folder = false; };
struct AccessibleState { std::mutex mutex; HWND window{}; std::vector<AccessibleNode> nodes; int focus = -1; unsigned long long focusRevision = 0; };
IRawElementProviderSimple* createAccessibility(const std::shared_ptr<AccessibleState>& state);
// Call on the window thread after changing the tree or native input focus.
// Focus -1 means the fragment has no keyboard focus; 0 denotes its root.
void updateAccessibility(const std::shared_ptr<AccessibleState>& state, IRawElementProviderSimple* root, std::vector<AccessibleNode> nodes, int focus);
}
