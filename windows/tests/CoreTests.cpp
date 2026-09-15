#include "core/State.h"
#include "platform/Integration.h"
#include "platform/Images.h"
#include <iostream>
#include <future>
#include <set>

using namespace frog;
namespace {
int passed = 0, failed = 0;
void test(const char* name, const std::function<void()>& run) {
    try { run(); ++passed; std::cout << "PASS " << name << '\n'; }
    catch (const std::exception& error) { ++failed; std::cerr << "FAIL " << name << ": " << error.what() << '\n'; }
}
void expect(bool condition) { require(condition, "断言失败"); }
void rejects(const std::function<void()>& run) { bool thrown = false; try { run(); } catch (const std::exception&) { thrown = true; } expect(thrown); }
struct Temporary {
    fs::path path = fs::temp_directory_path() / wide("Frog-test-" + uuid());
    Temporary() { fs::create_directories(path); }
    ~Temporary() { std::error_code ec; fs::remove_all(path, ec); }
};
Document sample() { Document data; data.upsert("", "第一条中文", "example.com", {}); auto group = data.addGroup("开发工具"); data.upsert("", "文档", "example.org/docs", group); return data; }
std::string iconFrames(const std::vector<Pixels>& frames) {
    std::string directory, payload;
    auto append = [&](uint32_t value, int bytes) { for (int i = 0; i < bytes; ++i) directory.push_back(static_cast<char>((value >> (i * 8)) & 255)); };
    append(0, 2); append(1, 2); append(static_cast<uint32_t>(frames.size()), 2);
    for (const auto& frame : frames) {
        auto png = encodePng(frame);
        append(frame.width % 256, 1); append(frame.height % 256, 1); append(0, 2); append(1, 2); append(32, 2);
        append(static_cast<uint32_t>(png.size()), 4); append(static_cast<uint32_t>(6 + frames.size() * 16 + payload.size()), 4);
        payload += png;
    }
    return directory + payload;
}
}
int wmain(int argc, wchar_t** argv) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED); ScopeExit cleanup{[] { CoUninitialize(); }};
    test("macos-v1-roundtrip", [&] { expect(argc == 2); auto bytes = readFile(argv[1]); auto data = Document::decode(bytes); expect(data == Document::decode(data.encode())); expect(data.groups[1].name == "空文件夹"); expect(!data.bookmarks[0].groupId); expect(data.bookmarks[0].createdAt == 1756000000000.125); });
    test("required-fields", [] { auto json = Json::parse(sample().encode()); json["bookmarks"][0].erase("groupId"); rejects([&] { Document::decode(json.dump()); }); });
    test("strict-numeric-schema", [] { auto json = Json::parse(sample().encode()); json["schemaVersion"] = 1.0; rejects([&] { Document::decode(json.dump()); }); json["schemaVersion"] = 1; json["groups"][0]["order"] = 0.5; rejects([&] { Document::decode(json.dump()); }); });
    test("future-version", [] { auto json = Json::parse(sample().encode()); json["schemaVersion"] = 2; rejects([&] { Document::decode(json.dump()); }); });
    test("duplicate-id-case-insensitive", [] { auto data = sample(); auto b = data.bookmarks[0]; b.id = lower(b.id); data.bookmarks.push_back(b); rejects([&] { data.validate(); }); });
    test("uuid-required", [] { auto data = sample(); data.bookmarks[0].id = "b-demo"; rejects([&] { data.validate(); }); });
    test("group-reference-required", [] { auto data = sample(); data.bookmarks[0].groupId = uuid(); rejects([&] { data.validate(); }); });
    test("unicode-graphemes", [] { expect(characters("👨‍👩‍👧") == 1); expect(characters("é") == 1); std::string title; for (int i = 0; i < 120; ++i) title += "中文"; auto data = sample(); rejects([&] { data.upsert("", title, "example.com", {}); }); });
    test("utf8-errors", [] { rejects([] { wide(std::string("\xff")); }); });
    test("url-ports-ipv6", [] { expect(normalizeUrl(" example.com:8080/path ") == "https://example.com:8080/path"); expect(normalizeUrl("[::1]:8080") == "https://[::1]:8080"); expect(normalizeUrl("localhost:9000") == "https://localhost:9000"); });
    test("url-rejects-unsafe-input", [] { for (const auto* value : {"javascript:alert(1)", "file:///C:/test", "mailto:a@b.com", "ftp://example.com", "not a domain", "https://", "https://example.com/a b"}) rejects([&] { normalizeUrl(value); }); });
    test("search-url-encoding", [] { expect(searchUrl("中文 & a").find("%26") != std::string::npos); expect(searchUrl("example.com") == "https://example.com"); });
    test("root-mixed-order", [] { auto data = sample(); auto first = data.bookmarks[0].id, group = data.groups[0].id; data.move(group, {}, first); expect(data.items()[0].id == group); data.move(first, group); expect(data.items().size() == 1); data.move(first, {}, group); expect(data.items()[0].id == first); });
    test("nonempty-folder-protected", [] { auto data = sample(); rejects([&] { data.remove(data.groups[0].id); }); });
    test("empty-folder-delete", [] { auto data = sample(); auto group = data.addGroup("空"); data.remove(group); expect(!data.group(group)); });
    test("invalid-edit-new-folder-rollback", [] { auto data = sample(), before = data; rejects([&] { data.upsert(uuid(), "标题", "example.com", {}, "新文件夹"); }); expect(data == before); });
    test("merge-keeps-target-and-empty-source-folder", [] { auto data = sample(); auto target = data.bookmarks[0].id, source = data.bookmarks[1].id, old = data.groups[0].id; auto merged = data.merge(source, target); expect(data.items(merged)[0].id == target); expect(data.items(merged)[1].id == source); expect(data.items(old).empty()); expect(data.items()[0].id == merged); data.validate(); });
    test("folder-cannot-nest", [] { auto data = sample(); auto another = data.addGroup("另一个"); auto before = data; rejects([&] { data.move(data.groups[0].id, another); }); expect(data == before); });
    test("invalid-reorder-rollback", [] { auto data = sample(), before = data; rejects([&] { data.reorder({}, {data.bookmarks[0].id, data.bookmarks[0].id}); }); expect(data == before); });
    test("extreme-order-normalized-on-edit", [] { auto data = sample(); data.bookmarks[0].order = INT64_MAX; auto json = data.encode(); expect(Document::decode(json).bookmarks[0].order == INT64_MAX); data.upsert("", "新", "example.com", {}); for (const auto& item : data.items()) expect(item.order < 4); });
    test("search-logical-order", [] { auto data = sample(); expect(data.search("EXAMPLE").size() == 2); expect(data.search("文档").front().id == data.bookmarks[1].id); expect(data.search("  ").size() == 2); });
    test("storage-atomic-save", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); auto data = sample(); auto next = store.save(data, state.bytes); expect(next.document == Document::decode(readFile(temp.path / "bookmarks.json"))); expect(std::distance(fs::directory_iterator(temp.path), fs::directory_iterator()) == 1); });
    test("conflict-preserves-external", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); auto external = sample(); atomicWrite(temp.path / "bookmarks.json", external.encode()); rejects([&] { store.save({}, state.bytes); }); expect(store.reload().document == external); });
    test("corrupt-file-preserved", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); atomicWrite(temp.path / "bookmarks.json", "{broken"); rejects([&] { store.reload(); }); rejects([&] { store.save(sample(), state.bytes); }); expect(readFile(temp.path / "bookmarks.json") == "{broken"); });
    test("missing-file-not-recreated-on-save", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); fs::remove(temp.path / "bookmarks.json"); rejects([&] { store.save(sample(), state.bytes); }); expect(!fs::exists(temp.path / "bookmarks.json")); });
    test("configured-file-missing-at-startup", [] { Temporary temp; Storage store; rejects([&] { store.open(temp.path, false, {}, false); }); expect(!fs::exists(temp.path / "bookmarks.json")); });
    test("read-only-target-rollback", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); auto path = temp.path / "bookmarks.json"; SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_READONLY); ScopeExit restore{[&] { SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL); }}; rejects([&] { store.save(sample(), state.bytes); }); expect(readFile(path) == state.bytes); });
    test("directory-unavailable", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); fs::remove(temp.path / "bookmarks.json"); fs::remove(temp.path); rejects([&] { store.save(sample(), state.bytes); }); });
    test("switch-seeds-empty-and-loads-existing", [] { Temporary a, b, c; Storage store; auto state = store.open(a.path, false, sample()); auto copied = store.open(b.path, false, state.document); expect(copied.document == state.document); auto existing = Document{}; atomicWrite(c.path / "bookmarks.json", existing.encode()); expect(store.open(c.path, false, state.document).document == existing); });
    test("invalid-switch-keeps-current-directory", [] { Temporary a, b; Storage store; auto state = store.open(a.path, false, sample()); atomicWrite(b.path / "bookmarks.json", "bad"); rejects([&] { store.open(b.path, false); }); expect(store.reload().directory == fs::weakly_canonical(a.path)); });
    test("backup-and-restore-replace-all", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false, sample()); auto backup = temp.path / "backup.json"; store.backup(backup, state.document); auto empty = store.save({}, state.bytes); expect(store.restore(backup, empty.bytes).document == state.document); rejects([&] { store.backup(temp.path / "bookmarks.json", state.document); }); });
    test("backup-hardlink-protected", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); auto alias = temp.path / "alias.json"; fs::create_hard_link(temp.path / "bookmarks.json", alias); rejects([&] { store.backup(alias, sample()); }); });
    test("invalid-restore-preserves-current", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false, sample()); atomicWrite(temp.path / "bad.json", "[]"); rejects([&] { store.restore(temp.path / "bad.json", state.bytes); }); expect(store.reload().document == state.document); });
    test("directory-watcher-atomic-replacement", [] { Temporary temp; Storage store; store.open(temp.path, false); std::atomic<int> changes{0}; DirectoryWatcher watcher; watcher.start(temp.path, [&] { ++changes; }); Sleep(80); atomicWrite(temp.path / "bookmarks.json", sample().encode()); for (int i = 0; i < 100 && changes == 0; ++i) Sleep(10); watcher.stop(); expect(changes > 0); });
    test("serial-queue-order", [] { std::vector<int> results; std::promise<void> done; { SerialQueue queue; for (int i = 0; i < 50; ++i) queue.post([&, i] { results.push_back(i); }); queue.post([&] { done.set_value(); }); expect(done.get_future().wait_for(std::chrono::seconds(3)) == std::future_status::ready); } for (int i = 0; i < 50; ++i) expect(results[i] == i); });
    test("folder-add-pagination", [] { Document data; auto group = data.addGroup("分页"); for (int i = 0; i < 12; ++i) data.upsert("", "书签", "example.com", group); ViewState state; state.layout = {1280, 800}; state.folder = group; expect(state.pageCount(data) == 2); state.turn(data, 1); expect(state.visibleItems(data).back().id == "__add__"); });
    test("keyboard-selection-crosses-pages", [] { Document data; for (int i = 0; i < 70; ++i) data.upsert("", "书签", "example.com", {}); ViewState state; state.select(data, 1); for (int i = 0; i < 35; ++i) state.select(data, 1); expect(state.page() > 0); expect(state.page() * state.layout.capacity(false) + state.selection == 35); });
    test("drag-cancel-restores-folder-page", [] { ViewState state; state.folder = "current"; state.folderPage = 1; DragState drag; drag.active = true; drag.originalFolder = "original"; drag.originalPage = 3; drag.cancel(state); expect(state.folder == Location("original") && state.page() == 3 && !drag.active); });
    test("layout-scales-small-display", [] { Layout layout{640, 480}; expect(layout.columns() == 3 && layout.rows() >= 1); auto last = layout.tile(layout.capacity(false) - 1, false); expect(last.x + last.width <= layout.width && last.y + last.height <= layout.height); });
    test("icon-html-relative-and-attribute-order", [] { auto urls = htmlIcons("<link href='../assets/a.png?x=1&amp;y=2' rel='shortcut icon'><link rel=icon href=/b.ico><link rel=stylesheet href=x.css>", "https://example.com/page/"); expect(urls.size() == 2); expect(urls[0] == "https://example.com/assets/a.png?x=1&y=2"); expect(urls[1] == "https://example.com/b.ico"); });
    test("icon-html-rejects-non-http", [] { expect(htmlIcons("<link rel='icon' href='data:image/png;base64,xyz'>", "https://example.com").empty()); });
    test("icon-html-svg-with-legacy-mime", [] {
        auto urls = htmlIcons("<link rel='icon' type='image/x-icon' href='https://cdn.example/favicon.svg'>", "https://example.com/usage");
        expect(urls == std::vector<std::string>{"https://cdn.example/favicon.svg"});
    });
    test("svg-path-renders-at-requested-resolution", [] {
        auto decoded = decodeImage(R"(<svg xmlns="http://www.w3.org/2000/svg" width="50" height="50"><path fill="#ff0000" d="M0 0H25V50H0Z"/></svg>)", 128);
        expect(decoded->width == 128 && decoded->height == 128);
        size_t red = (64 * 128 + 32) * 4, transparent = (64 * 128 + 96) * 4;
        expect(decoded->bgra[red] == 0 && decoded->bgra[red + 1] == 0 && decoded->bgra[red + 2] == 255 && decoded->bgra[red + 3] == 255);
        expect(decoded->bgra[transparent + 3] == 0);
        auto cached = decodeImage(encodePng(*decoded), 128);
        expect(cached->bgra == decoded->bgra);
    });
    test("svg-viewbox-center-crop-and-alpha", [] {
        auto decoded = decodeImage(R"(<svg xmlns="http://www.w3.org/2000/svg" viewBox="10 20 96 32"><path fill="red" d="M10 20H42V52H10Z M74 20H106V52H74Z"/><path fill="#00ff00" fill-opacity="0.5" d="M42 28H74V44H42Z"/></svg>)", 32);
        expect(decoded->bgra[3] == 0);
        for (UINT x = 0; x < 32; ++x) {
            size_t pixel = (16 * 32 + x) * 4;
            expect(decoded->bgra[pixel] == 0 && decoded->bgra[pixel + 2] == 0);
            expect(decoded->bgra[pixel + 1] >= 127 && decoded->bgra[pixel + 1] <= 128);
            expect(decoded->bgra[pixel + 3] == decoded->bgra[pixel + 1]);
        }
    });
    test("svg-rejects-invalid-document-and-size", [] {
        for (const auto* svg : {
            "<svg xmlns='http://www.w3.org/2000/svg'><path",
            "<html><body>Not an icon</body></html>",
            "<svg xmlns='http://www.w3.org/2000/svg' width='0' height='0'/>",
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 0 32'/>",
            "<svg xmlns='http://www.w3.org/2000/svg' width='4097' height='1'/>"
        }) rejects([&] { decodeImage(svg, 64); });
    });
    test("svg-png-cache-loads-offline", [] {
        Temporary temp; const std::string url = "https://example.com/usage";
        auto rendered = decodeImage(R"(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50"><path fill="blue" d="M0 0H50V50H0Z"/></svg>)", 64);
        atomicWrite(temp.path / wide(hash(url) + ".png"), encodePng(*rendered));
        std::promise<std::shared_ptr<Pixels>> loaded;
        Images images(temp.path, true, [&](uint64_t, std::string, std::shared_ptr<Pixels> pixels) { loaded.set_value(pixels); });
        images.resume(); images.request(url, 64);
        auto result = loaded.get_future();
        expect(result.wait_for(std::chrono::seconds(3)) == std::future_status::ready);
        auto cached = result.get(); expect(cached && cached->bgra == rendered->bgra);
    });
    test("wic-png-roundtrip-and-size", [] { Pixels image{32, 32, std::vector<unsigned char>(32 * 32 * 4, 255)}; auto png = encodePng(image); auto decoded = decodeImage(png, 64); expect(decoded->width == 64 && decoded->height == 64 && decoded->bgra.size() == 64 * 64 * 4); rejects([] { decodeImage("broken", 64); }); });
    test("wic-ico-prefers-largest-frame", [] {
        Pixels smallFrame{16, 16, std::vector<unsigned char>(16 * 16 * 4, 255)};
        Pixels large{64, 64, std::vector<unsigned char>(64 * 64 * 4, 255)};
        Pixels medium{32, 32, std::vector<unsigned char>(32 * 32 * 4, 255)};
        for (size_t i = 0; i < large.bgra.size(); i += 4) large.bgra[i] = large.bgra[i + 2] = 0;
        auto decoded = decodeImage(iconFrames({smallFrame, large, medium}), 72);
        size_t center = (36 * 72 + 36) * 4;
        expect(decoded->width == 72 && decoded->height == 72);
        expect(decoded->bgra[center] == 0 && decoded->bgra[center + 1] == 255 && decoded->bgra[center + 2] == 0);
    });
    test("wic-fill-crops-center-and-preserves-transparency", [] {
        Pixels image{96, 32, std::vector<unsigned char>(96 * 32 * 4, 0)};
        for (UINT y = 0; y < 32; ++y) for (UINT x = 0; x < 96; ++x) {
            size_t pixel = (y * 96 + x) * 4;
            if (x < 32 || x >= 64) { image.bgra[pixel + 2] = image.bgra[pixel + 3] = 255; }
            else if (y >= 8 && y < 24) { image.bgra[pixel + 1] = image.bgra[pixel + 3] = 255; }
        }
        auto decoded = decodeImage(encodePng(image), 32);
        expect(decoded->bgra[3] == 0);
        for (UINT x = 0; x < 32; ++x) {
            size_t pixel = (16 * 32 + x) * 4;
            expect(decoded->bgra[pixel + 1] == 255 && decoded->bgra[pixel + 2] == 0 && decoded->bgra[pixel + 3] == 255);
        }
    });
    test("offline-icon-cache", [] { Temporary temp; auto url = std::string("https://example.com"); Pixels image{32, 32, std::vector<unsigned char>(32 * 32 * 4, 255)}; atomicWrite(temp.path / wide(hash(url) + ".png"), encodePng(image)); std::promise<bool> loaded; Images images(temp.path, true, [&](uint64_t, std::string, std::shared_ptr<Pixels> pixels) { loaded.set_value(pixels != nullptr); }); images.resume(); images.request(url, 64); auto result = loaded.get_future(); expect(result.wait_for(std::chrono::seconds(3)) == std::future_status::ready && result.get()); });
    test("global-hotkey-conflict-keeps-old", [] { auto a = CreateWindowExW(0, L"STATIC", L"FrogTestA", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, nullptr, nullptr); auto b = CreateWindowExW(0, L"STATIC", L"FrogTestB", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, nullptr, nullptr); ScopeExit close{[&] { DestroyWindow(a); DestroyWindow(b); }}; GlobalHotKey first, second; HotKey key{true, MOD_CONTROL | MOD_ALT | MOD_SHIFT, VK_F23}; first.set(a, key); rejects([&] { second.set(b, key); }); first.set(a, {false}); second.set(b, key); });
    std::cout << passed << " passed, " << failed << " failed\n"; return failed ? 1 : 0;
}
