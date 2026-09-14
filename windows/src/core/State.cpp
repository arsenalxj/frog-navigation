#include "State.h"
#include <algorithm>

namespace frog {
int Layout::columns() const { return std::clamp(static_cast<int>((width - 200) / 134), 3, 8); }
int Layout::rows() const { return std::clamp(static_cast<int>((height - 212) / 128), 1, 4); }
int Layout::capacity(bool folder) const { return folder ? std::min(4, columns()) * std::min(3, rows()) : columns() * rows(); }
Rect Layout::folderBounds() const {
    float w = std::min(width - 40, 580.0f), h = std::min(height - 130, 490.0f);
    return {(width - w) / 2, std::max(85.0f, (height - h) / 2), w, h};
}
Rect Layout::tile(int index, bool folder) const {
    int cols = folder ? std::min(4, columns()) : columns();
    int rs = folder ? std::min(3, rows()) : rows();
    float pitchX = folder ? 124.0f : 130.0f, pitchY = 128.0f;
    float top = folder ? folderBounds().y + 72 : 100 + (height - 160 - rs * pitchY) / 2;
    return {(width - (cols - 1) * pitchX - 104) / 2 + (index % cols) * pitchX, top + (index / cols) * pitchY, 104, 112};
}
int& ViewState::page() { return searching() ? searchPage : (folder ? folderPage : rootPage); }
int ViewState::page() const { return searching() ? searchPage : (folder ? folderPage : rootPage); }
std::vector<Item> ViewState::allItems(const Document& document) const {
    auto items = searching() ? document.search(query) : document.items(folder);
    if (inFolder()) items.push_back({"__add__", "添加书签", 0, false}); return items;
}
std::vector<Item> ViewState::visibleItems(const Document& document) const {
    auto all = allItems(document); int cap = layout.capacity(inFolder());
    size_t first = std::min(all.size(), static_cast<size_t>(std::max(0, page()) * cap));
    size_t last = std::min(all.size(), first + cap); return {all.begin() + first, all.begin() + last};
}
int ViewState::pageCount(const Document& document) const {
    int cap = layout.capacity(inFolder()); return std::max(1, (static_cast<int>(allItems(document).size()) + cap - 1) / cap);
}
void ViewState::clamp(const Document& document) {
    if (folder && !document.group(*folder)) { folder.reset(); folderPage = 0; }
    page() = std::clamp(page(), 0, pageCount(document) - 1);
    selection = std::clamp(selection, -1, static_cast<int>(visibleItems(document).size()) - 1);
}
void ViewState::turn(const Document& document, int delta) { page() += delta; selection = -1; clamp(document); }
void ViewState::select(const Document& document, int delta) {
    auto all = allItems(document); if (all.empty()) return;
    int cap = layout.capacity(inFolder());
    int target = selection < 0 ? page() * cap : page() * cap + selection + delta;
    target = std::clamp(target, 0, static_cast<int>(all.size()) - 1); page() = target / cap; selection = target % cap;
}
void ViewState::reveal(const Document& document, const std::string& id) {
    query.clear(); if (auto b = document.bookmark(id)) folder = b->groupId;
    auto all = allItems(document);
    for (size_t i = 0; i < all.size(); ++i) if (all[i].id == id) { page() = static_cast<int>(i) / layout.capacity(inFolder()); selection = static_cast<int>(i) % layout.capacity(inFolder()); }
    clamp(document);
}
void DragState::cancel(ViewState& state) {
    if (active) { state.folder = originalFolder; state.page() = originalPage; }
    *this = {};
}
}
