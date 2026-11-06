#include "EdgeBookmarks.h"
#include <algorithm>
#include <charconv>
#include <cmath>
#include <fstream>
#include <icu.h>
#include <iterator>
#include <utility>
#include <limits>
#include <map>
#include <set>
#include <shlobj.h>

namespace frog::edge {
namespace {
double now() { return std::chrono::duration<double, std::milli>(std::chrono::system_clock::now().time_since_epoch()).count(); }
std::string string(const Json& row, const char* key) {
    auto it = row.find(key); return it != row.end() && it->is_string() ? it->get<std::string>() : std::string{};
}
std::string cleaned(const std::string& value) {
    std::string result; result.reserve(value.size());
    for (size_t i = 0; i < value.size(); ++i) {
        char c = value[i];
        if (c == '\r' && i + 1 < value.size() && value[i + 1] == '\n') ++i;
        result += c == '\r' || c == '\n' || c == '\t' ? ' ' : c;
    }
    return trim(result);
}
std::string limited(const std::string& value) {
    auto text = wide(value); UErrorCode error = U_ZERO_ERROR;
    auto* iterator = ubrk_open(UBRK_CHARACTER, "", reinterpret_cast<const UChar*>(text.data()), static_cast<int32_t>(text.size()), &error);
    require(U_SUCCESS(error) && iterator, "无法检查文字长度。");
    ScopeExit close{[&] { ubrk_close(iterator); }};
    size_t count = 0; while (ubrk_next(iterator) != UBRK_DONE) ++count;
    if (count <= 120) return value;
    ubrk_last(iterator); int32_t start = 0;
    for (size_t i = 0; i < 119; ++i) start = ubrk_previous(iterator);
    return "…" + utf8(text.substr(start));
}
double timestamp(const Json& row) {
    auto it = row.find("date_added"); if (it == row.end()) it = row.find("date_modified");
    if (it == row.end()) return now();
    int64_t micros = 0;
    if (it->is_string()) {
        const auto& text = it->get_ref<const std::string&>();
        const char* first = text.data(); const char* last = first + text.size();
        if (first != last && *first == '+') ++first;
        auto parsed = std::from_chars(first, last, micros);
        if (parsed.ec != std::errc{} || parsed.ptr != last) return now();
    } else if (it->is_number_unsigned()) {
        auto value = it->get<uint64_t>(); if (value > INT64_MAX) return now(); micros = static_cast<int64_t>(value);
    } else if (it->is_number_integer()) micros = it->get<int64_t>();
    else if (it->is_number_float()) {
        double value = it->get<double>();
        if (!std::isfinite(value) || value < -9223372036854775808.0 || value >= 9223372036854775808.0) return now();
        micros = static_cast<int64_t>(value);
    } else return now();
    double millis = (static_cast<double>(micros) - 11644473600000000.0) / 1000;
    return micros > 0 && std::isfinite(millis) && millis >= 0 ? millis : now();
}
struct Accumulator {
    EdgeImportPayload payload;
    std::map<std::string, size_t> indices;
    void walk(const Json& children, const std::string& path) {
        require(children.is_array(), "Edge 文件夹内容损坏，未导入任何内容。");
        auto name = limited(path);
        auto [it, inserted] = indices.emplace(name, payload.folders.size());
        if (inserted) payload.folders.push_back({name, {}});
        const size_t index = it->second;
        for (const auto& row : children) {
            require(row.is_object(), "Edge 文件夹内容损坏，未导入任何内容。");
            auto type = string(row, "type");
            if (type == "folder") {
                auto childName = cleaned(string(row, "name")); if (childName.empty()) childName = "未命名文件夹";
                auto child = row.find("children"); require(child != row.end(), "Edge 文件夹内容损坏，未导入任何内容。");
                walk(*child, path + " / " + childName); continue;
            }
            auto urlNode = row.find("url");
            require(type == "url" && urlNode != row.end() && urlNode->is_string(), "Edge 书签节点无效，未导入任何内容。");
            auto url = trim(urlNode->get<std::string>());
            if (!validUrl(url)) { ++payload.unsupported; continue; }
            auto title = cleaned(string(row, "name")); if (title.empty()) title = url;
            payload.folders[index].bookmarks.push_back({limited(title), std::move(url), timestamp(row)});
        }
    }
};
bool profileLess(const fs::path& a, const fs::path& b) {
    auto lhs = a.filename().wstring(), rhs = b.filename().wstring();
    if ((lhs == L"Default") != (rhs == L"Default")) return lhs == L"Default";
    return CompareStringEx(LOCALE_NAME_USER_DEFAULT, SORT_DIGITSASNUMBERS, lhs.data(), static_cast<int>(lhs.size()), rhs.data(), static_cast<int>(rhs.size()), nullptr, nullptr, 0) == CSTR_LESS_THAN;
}
}
fs::path defaultDataRoot() {
    DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
    if (length) {
        std::wstring value(length, L'\0'); DWORD copied = GetEnvironmentVariableW(L"LOCALAPPDATA", value.data(), length);
        if (copied && copied < length) { value.resize(copied); return fs::path(value) / L"Microsoft" / L"Edge" / L"User Data"; }
    }
    PWSTR value = nullptr; check(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &value), "无法读取本地应用数据目录。");
    ScopeExit release{[&] { CoTaskMemFree(value); }};
    return fs::path(value) / L"Microsoft" / L"Edge" / L"User Data";
}
EdgeImportPayload parse(const std::string& bytes, const std::string& label) {
    require(bytes.size() <= maximumBytes, "Edge 书签文件超过 32 MB，无法导入。");
    auto object = Json::parse(bytes, nullptr, false);
    require(object.is_object() && object.contains("roots") && object["roots"].is_object(), "无法识别 Edge 书签文件结构，文件可能已损坏。");
    const auto& roots = object["roots"]; Accumulator accumulator;
    for (const auto& [key, fallback] : {std::pair{"bookmark_bar", "收藏夹栏"}, std::pair{"other", "其他收藏夹"}}) {
        auto it = roots.find(key); if (it == roots.end()) continue;
        require(it->is_object() && string(*it, "type") == "folder", "Edge 收藏夹根节点无效，未导入任何内容。");
        auto name = cleaned(string(*it, "name")); if (name.empty()) name = fallback;
        if (!label.empty()) name = "[" + label + "] " + name;
        auto children = it->find("children"); require(children != it->end(), "Edge 文件夹内容损坏，未导入任何内容。");
        accumulator.walk(*children, name);
    }
    require(!accumulator.payload.folders.empty(), "Edge 文件缺少收藏夹栏和其他收藏夹，无法导入。");
    accumulator.payload.profiles = 1; return std::move(accumulator.payload);
}
EdgeImportPayload load(const fs::path& root) {
    try {
        require(fs::exists(root), "未找到 Edge 数据目录：" + utf8(root.wstring()) + "。请确认已安装 Microsoft Edge。");
        std::vector<fs::path> sources;
        bool directory = fs::is_directory(root);
        if (!directory) sources.push_back(root);
        else if (fs::exists(root / L"Bookmarks")) sources.push_back(root / L"Bookmarks");
        else {
            std::vector<fs::path> profiles;
            for (const auto& entry : fs::directory_iterator(root)) {
                auto name = entry.path().filename().wstring();
                auto attributes = GetFileAttributesW(entry.path().c_str());
                if (name.empty() || name.front() == L'.' || (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_HIDDEN)) || name == L"Guest Profile" || name == L"System Profile") continue;
                if (entry.is_directory() && fs::exists(entry.path() / L"Bookmarks")) profiles.push_back(entry.path());
            }
            std::sort(profiles.begin(), profiles.end(), profileLess);
            for (const auto& profile : profiles) sources.push_back(profile / L"Bookmarks");
        }
        require(!sources.empty(), "Edge 数据目录里没有找到 Bookmarks 文件：" + utf8(root.wstring()));
        EdgeImportPayload result; result.profiles = sources.size();
        for (const auto& file : sources) {
            auto path = utf8(file.wstring());
            require(fs::is_regular_file(file), "Edge 书签数据必须是普通文件：" + path);
            auto size = fs::file_size(file); require(size <= maximumBytes, "Edge 书签文件超过 32 MB：" + path);
            std::ifstream stream(file, std::ios::binary); require(stream.is_open(), "无法读取 Edge 书签文件：" + path);
            std::string bytes(static_cast<size_t>(size), '\0');
            stream.read(bytes.data(), static_cast<std::streamsize>(size));
            require(stream.gcount() == static_cast<std::streamsize>(size) && !stream.bad(), "无法读取 Edge 书签文件：" + path);
            require(stream.peek() == std::char_traits<char>::eof(), "Edge 书签文件读取期间发生变化，未导入任何内容。");
            EdgeImportPayload parsed;
            try { parsed = parse(bytes, sources.size() > 1 ? utf8(file.parent_path().filename().wstring()) : ""); }
            catch (const Error& error) { throw Error("无法导入 " + path + "：" + error.what()); }
            result.unsupported += parsed.unsupported;
            result.folders.insert(result.folders.end(), std::make_move_iterator(parsed.folders.begin()), std::make_move_iterator(parsed.folders.end()));
        }
        return result;
    } catch (const fs::filesystem_error& error) { throw Error("无法读取 Edge 书签文件：" + std::string(error.what())); }
}
EdgeImportResult importPayload(const Document& source, const EdgeImportPayload& payload) {
    EdgeImportResult result{source, {}}; auto& document = result.document; auto& summary = result.summary;
    summary.profiles = payload.profiles; summary.unsupported = payload.unsupported;
    std::set<std::string> urls; std::map<std::string, std::string> groupIDs;
    int64_t maxRoot = -1;
    for (const auto& group : document.groups) { groupIDs[group.name] = group.id; maxRoot = (std::max)(maxRoot, group.order); }
    size_t incoming = 0; for (const auto& folder : payload.folders) incoming += folder.bookmarks.size();
    std::set<std::string> crowded;
    for (const auto& bookmark : document.bookmarks) {
        urls.insert(bookmark.url);
        if (!bookmark.groupId) maxRoot = (std::max)(maxRoot, bookmark.order);
        else if (bookmark.order >= INT64_MAX - static_cast<int64_t>(incoming)) crowded.insert(*bookmark.groupId);
    }
    for (const auto& id : crowded) document.normalize(id);
    int64_t rootOrder;
    if (maxRoot >= INT64_MAX - static_cast<int64_t>(payload.folders.size())) { document.normalize({}); rootOrder = static_cast<int64_t>(document.items().size()); }
    else rootOrder = maxRoot + 1;
    std::map<std::string, int64_t> nextOrders;
    for (const auto& bookmark : document.bookmarks) if (bookmark.groupId) nextOrders[*bookmark.groupId] = (std::max)(nextOrders[*bookmark.groupId], bookmark.order + 1);
    for (const auto& folder : payload.folders) {
        auto name = limited(trim(folder.name)); if (name.empty()) continue;
        auto [it, inserted] = groupIDs.try_emplace(name);
        if (inserted) { it->second = uuid(); document.groups.push_back({it->second, name, rootOrder++}); ++summary.groups; }
        const auto& id = it->second;
        for (const auto& entry : folder.bookmarks) {
            auto url = trim(entry.url);
            if (!validUrl(url)) { ++summary.unsupported; continue; }
            if (!urls.insert(url).second) { ++summary.duplicates; continue; }
            auto title = trim(entry.title); if (title.empty()) title = url;
            document.bookmarks.push_back({uuid(), limited(title), std::move(url), id, nextOrders[id]++, std::isfinite(entry.createdAt) && entry.createdAt >= 0 ? entry.createdAt : now()});
            ++summary.inserted;
        }
    }
    document.validate(); return result;
}
EdgeImportResult importFrom(const Document& source, const fs::path& root) { return importPayload(source, load(root)); }
}
