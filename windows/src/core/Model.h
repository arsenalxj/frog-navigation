#pragma once
#include "Util.h"
#include <json.hpp>

namespace frog {
using Json = nlohmann::json;
using Location = std::optional<std::string>;
struct Bookmark {
    std::string id, title, url;
    Location groupId;
    int64_t order = 0;
    double createdAt = 0;
    bool operator==(const Bookmark&) const = default;
};
struct Group {
    std::string id, name;
    int64_t order = 0;
    bool operator==(const Group&) const = default;
};
struct Item {
    std::string id, title;
    int64_t order = 0;
    bool folder = false;
    bool operator==(const Item&) const = default;
};
struct Document {
    std::vector<Group> groups;
    std::vector<Bookmark> bookmarks;
    static Document decode(const std::string& bytes);
    std::string encode() const;
    void validate() const;
    const Bookmark* bookmark(const std::string& id) const;
    const Group* group(const std::string& id) const;
    std::vector<Item> items(Location location = {}) const;
    std::vector<Item> search(const std::string& query) const;
    std::string addGroup(const std::string& name);
    void renameGroup(const std::string& id, const std::string& name);
    std::string upsert(const std::string& id, const std::string& title, const std::string& url, Location location, const std::string& newGroup = {});
    void remove(const std::string& id);
    void move(const std::string& id, Location location, const std::string& before = {});
    std::string merge(const std::string& source, const std::string& target);
    void reorder(Location location, const std::vector<std::string>& ids);
    void normalize(Location location);
    bool operator==(const Document&) const = default;
};
bool validUrl(const std::string& url);
std::string normalizeUrl(const std::string& input);
std::string searchUrl(const std::string& input);
}
