#pragma once
#include "core/State.h"
#include <UIAutomation.h>
#include <mutex>
#include <memory>

namespace frog {
struct AccessibleNode { int token{}; std::wstring name, help; RECT bounds{}; bool selected = false, enabled = true, folder = false; };
struct AccessibleState { std::mutex mutex; HWND window{}; std::vector<AccessibleNode> nodes; int focus = 0; };
IRawElementProviderSimple* createAccessibility(const std::shared_ptr<AccessibleState>& state);
}
