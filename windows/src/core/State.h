#pragma once
#include "Model.h"

namespace frog {
struct Rect {
    float x{}, y{}, width{}, height{};
    bool contains(float px, float py) const { return px >= x && px <= x + width && py >= y && py <= y + height; }
};
struct Layout {
    float width = 1280, height = 720;
    int columns() const;
    int rows() const;
    int capacity(bool folder) const;
    Rect folderBounds() const;
    Rect tile(int index, bool folder) const;
};
struct ViewState {
    Location folder;
    std::string query;
    int rootPage = 0, folderPage = 0, searchPage = 0, selection = -1;
    bool organizing = false;
    Layout layout;
    bool searching() const { return !trim(query).empty(); }
    bool inFolder() const { return folder.has_value() && !searching(); }
    int& page();
    int page() const;
    std::vector<Item> allItems(const Document& document) const;
    std::vector<Item> visibleItems(const Document& document) const;
    int pageCount(const Document& document) const;
    void clamp(const Document& document);
    void turn(const Document& document, int delta);
    void select(const Document& document, int delta);
    void reveal(const Document& document, const std::string& id);
};
struct DragState {
    std::string source, hover;
    Location originalFolder;
    int originalPage = 0;
    double hoverSince = 0, edgeSince = 0;
    int edge = 0;
    bool active = false, held = false;
    float startX = 0, startY = 0, x = 0, y = 0;
    void cancel(ViewState& state);
};
}
