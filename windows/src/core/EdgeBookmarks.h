#pragma once
#include "Model.h"

namespace frog {
struct EdgeBookmarkEntry { std::string title, url; double createdAt = 0; };
struct EdgeFolder { std::string name; std::vector<EdgeBookmarkEntry> bookmarks; };
struct EdgeImportPayload { std::vector<EdgeFolder> folders; size_t profiles = 0, unsupported = 0; };
struct EdgeImportSummary { size_t profiles = 0, groups = 0, inserted = 0, duplicates = 0, unsupported = 0; };
struct EdgeImportResult { Document document; EdgeImportSummary summary; };
namespace edge {
inline constexpr size_t maximumBytes = 32 * 1024 * 1024;
fs::path defaultDataRoot();
EdgeImportPayload parse(const std::string& bytes, const std::string& label = {});
EdgeImportPayload load(const fs::path& root);
// Never mutates the source or writes preferences; callers commit the returned document once.
EdgeImportResult importPayload(const Document& source, const EdgeImportPayload& payload);
EdgeImportResult importFrom(const Document& source, const fs::path& root);
}
}
