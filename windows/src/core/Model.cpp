#include "Model.h"
#include <winhttp.h>
#include <set>
#include <algorithm>
#include <cmath>

namespace frog {
namespace {
bool validId(const std::string& id) {
    if (id.size() != 36) return false;
    for (size_t i = 0; i < id.size(); ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (id[i] != '-') return false; }
        else if (!isxdigit(static_cast<unsigned char>(id[i]))) return false;
    }
    return true;
}
std::string checkedName(const std::string& value) {
    auto name = trim(value);
    require(!name.empty() && characters(name) <= 120, "名称不能为空，且不能超过 120 个字符。"); return name;
}
int64_t readOrder(const Json& value) {
    require(value.is_number_integer() && (!value.is_number_unsigned() || value.get<uint64_t>() <= INT64_MAX), "排序字段必须是有效整数。");
    return value.get<int64_t>();
}
}
bool validUrl(const std::string& url) {
    auto value = wide(url);
    if (value.empty() || value.find(L'\0') != std::wstring::npos) return false;
    for (wchar_t c : value) if (iswspace(c) || c < 32 || c == 0x3000) return false;
    URL_COMPONENTS parts{sizeof(parts)};
    parts.dwHostNameLength = static_cast<DWORD>(-1);
    return WinHttpCrackUrl(value.c_str(), 0, 0, &parts) &&
        (parts.nScheme == INTERNET_SCHEME_HTTP || parts.nScheme == INTERNET_SCHEME_HTTPS) && parts.dwHostNameLength > 0;
}
std::string normalizeUrl(const std::string& input) {
    auto result = trim(input);
    if (result.find("://") == std::string::npos) {
        auto host = result.substr(0, result.find('/'));
        require(host.find('@') == std::string::npos && !host.empty() && host.front() != '.' && host.back() != '.' &&
            (host.find('.') != std::string::npos || host == "localhost" || host.starts_with("localhost:") || host.starts_with("[")), "请输入有效网址，例如 example.com。");
        result = "https://" + result;
    }
    require(validUrl(result), "网址仅支持有效的 http 或 https 地址。"); return result;
}
std::string searchUrl(const std::string& input) {
    try { return normalizeUrl(input); } catch (const Error&) { return "https://www.google.com/search?q=" + percentEncode(trim(input)); }
}
Document Document::decode(const std::string& bytes) {
    try {
        auto data = Json::parse(bytes);
        require(data.at("format") == "frog-bookmarks" && data.at("schemaVersion").is_number_integer() && data.at("schemaVersion") == 1, "该文件不是受支持的青蛙导航书签备份（格式版本 1）。");
        require(data.at("groups").is_array() && data.at("bookmarks").is_array(), "书签与文件夹必须是数组。");
        Document result;
        for (const auto& g : data.at("groups")) result.groups.push_back({g.at("id").get<std::string>(), g.at("name").get<std::string>(), readOrder(g.at("order"))});
        for (const auto& b : data.at("bookmarks")) {
            Location location;
            if (!b.at("groupId").is_null()) location = b.at("groupId").get<std::string>();
            result.bookmarks.push_back({b.at("id").get<std::string>(), b.at("title").get<std::string>(), b.at("url").get<std::string>(), location, readOrder(b.at("order")), b.at("createdAt").get<double>()});
        }
        result.validate(); return result;
    } catch (const Json::exception&) { throw Error("无法解析书签文件，必要字段缺失、类型错误或 JSON 已损坏。"); }
}
std::string Document::encode() const {
    validate(); Json data{{"format", "frog-bookmarks"}, {"schemaVersion", 1}, {"groups", Json::array()}, {"bookmarks", Json::array()}};
    for (const auto& g : groups) data["groups"].push_back({{"id", g.id}, {"name", g.name}, {"order", g.order}});
    for (const auto& b : bookmarks) data["bookmarks"].push_back({{"id", b.id}, {"title", b.title}, {"url", b.url}, {"groupId", b.groupId ? Json(*b.groupId) : Json(nullptr)}, {"order", b.order}, {"createdAt", b.createdAt}});
    return data.dump(2) + "\n";
}
void Document::validate() const {
    std::set<std::string> ids;
    for (const auto& g : groups) {
        require(validId(g.id) && ids.insert(lower(g.id)).second, "文件夹 ID 无效或重复。");
        checkedName(g.name); require(g.order >= 0, "文件夹排序无效。");
    }
    for (const auto& b : bookmarks) {
        require(validId(b.id) && ids.insert(lower(b.id)).second, "书签 ID 无效或重复。");
        checkedName(b.title);
        require(b.order >= 0 && std::isfinite(b.createdAt) && b.createdAt >= 0, "书签时间或排序无效。");
        require(validUrl(b.url), "书签网址必须是有效的 http 或 https 地址。");
        require(!b.groupId || group(*b.groupId), "书签引用了不存在的文件夹。");
    }
}
const Bookmark* Document::bookmark(const std::string& id) const {
    auto it = std::find_if(bookmarks.begin(), bookmarks.end(), [&](const auto& b) { return b.id == id; });
    return it == bookmarks.end() ? nullptr : &*it;
}
const Group* Document::group(const std::string& id) const {
    auto it = std::find_if(groups.begin(), groups.end(), [&](const auto& g) { return g.id == id; });
    return it == groups.end() ? nullptr : &*it;
}
std::vector<Item> Document::items(Location location) const {
    std::vector<Item> out;
    if (!location) for (const auto& g : groups) out.push_back({g.id, g.name, g.order, true});
    for (const auto& b : bookmarks) if (b.groupId == location) out.push_back({b.id, b.title, b.order, false});
    std::sort(out.begin(), out.end(), [](const auto& a, const auto& b) { return a.order == b.order ? a.id < b.id : a.order < b.order; });
    return out;
}
std::vector<Item> Document::search(const std::string& query) const {
    std::vector<Item> out; auto text = lower(trim(query));
    auto add = [&](const Item& item) { const auto* b = bookmark(item.id); if (b && (lower(b->title).find(text) != std::string::npos || lower(b->url).find(text) != std::string::npos)) out.push_back(item); };
    for (const auto& item : items()) { if (item.folder) for (const auto& child : items(item.id)) add(child); else add(item); }
    return out;
}
void Document::reorder(Location location, const std::vector<std::string>& ids) {
    auto current = items(location); std::set<std::string> expected, actual(ids.begin(), ids.end());
    for (const auto& item : current) expected.insert(item.id);
    require(expected == actual && ids.size() == actual.size(), "内容已改变，请重试排序。");
    for (size_t i = 0; i < ids.size(); ++i) {
        for (auto& b : bookmarks) if (b.id == ids[i]) b.order = static_cast<int64_t>(i);
        if (!location) for (auto& g : groups) if (g.id == ids[i]) g.order = static_cast<int64_t>(i);
    }
}
void Document::normalize(Location location) {
    std::vector<std::string> ids; for (const auto& item : items(location)) ids.push_back(item.id); reorder(location, ids);
}
std::string Document::addGroup(const std::string& name) {
    auto title = checkedName(name); normalize({}); auto id = uuid();
    groups.push_back({id, title, static_cast<int64_t>(items().size())}); return id;
}
void Document::renameGroup(const std::string& id, const std::string& name) {
    auto title = checkedName(name); require(group(id), "该文件夹已不存在。");
    for (auto& g : groups) if (g.id == id) g.name = title;
}
std::string Document::upsert(const std::string& id, const std::string& title, const std::string& url, Location location, const std::string& newGroup) {
    auto next = *this; auto checkedTitle = checkedName(title); auto checkedUrl = normalizeUrl(url);
    if (!id.empty()) require(bookmark(id), "该书签已不存在，请重新选择。");
    if (!newGroup.empty()) location = next.addGroup(newGroup);
    require(!location || next.group(*location), "所选文件夹已不存在。");
    auto result = id.empty() ? uuid() : id;
    if (id.empty()) {
        next.normalize(location);
        double created = std::chrono::duration<double, std::milli>(std::chrono::system_clock::now().time_since_epoch()).count();
        next.bookmarks.push_back({result, checkedTitle, checkedUrl, location, static_cast<int64_t>(next.items(location).size()), created});
    } else {
        if (next.bookmark(id)->groupId != location) next.move(id, location);
        for (auto& b : next.bookmarks) if (b.id == id) { b.title = checkedTitle; b.url = checkedUrl; }
    }
    next.validate(); *this = std::move(next); return result;
}
void Document::remove(const std::string& id) {
    if (auto b = bookmark(id)) {
        auto location = b->groupId; std::erase_if(bookmarks, [&](const auto& v) { return v.id == id; }); normalize(location);
    } else {
        require(group(id), "该文件夹已不存在。"); require(items(id).empty(), "请先移出或删除文件夹内的书签，再删除文件夹。");
        std::erase_if(groups, [&](const auto& v) { return v.id == id; }); normalize({});
    }
}
void Document::move(const std::string& id, Location location, const std::string& before) {
    if (id == before) return;
    require(!location || group(*location), "所选文件夹已不存在。");
    const auto* b = bookmark(id);
    require(b || group(id), "拖动条目已不存在。"); require(b || !location, "文件夹只支持单层结构。");
    Location previous = b ? b->groupId : Location{};
    std::vector<std::string> ids; for (const auto& item : items(location)) if (item.id != id) ids.push_back(item.id);
    auto position = before.empty() ? ids.end() : std::find(ids.begin(), ids.end(), before);
    require(before.empty() || position != ids.end(), "拖拽目标已改变，请重试。"); ids.insert(position, id);
    for (auto& entry : bookmarks) if (entry.id == id) entry.groupId = location;
    if (previous != location) normalize(previous);
    reorder(location, ids);
}
std::string Document::merge(const std::string& source, const std::string& target) {
    auto s = bookmark(source), t = bookmark(target);
    require(s && t && source != target && !t->groupId, "只能在根目录将两条不同书签组成文件夹。");
    auto old = s->groupId; auto order = t->order; std::vector<std::string> root;
    auto id = uuid(); for (const auto& item : items()) if (item.id != source) root.push_back(item.id == target ? id : item.id);
    groups.push_back({id, "新建文件夹", order});
    for (auto& b : bookmarks) { if (b.id == target) { b.groupId = id; b.order = 0; } if (b.id == source) { b.groupId = id; b.order = 1; } }
    reorder({}, root); if (old) normalize(old); return id;
}
}
