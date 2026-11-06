#include "core/Calculator.h"
#include "core/EdgeBookmarks.h"
#include <cmath>
#include <fstream>
#include <iostream>
#include <limits>

using namespace frog;
namespace {
int failures = 0;
void expect(bool condition) { require(condition, "断言失败"); }
void test(const char* name, const std::function<void()>& run) {
    try { run(); std::cout << "PASS " << name << '\n'; }
    catch (const std::exception& error) { ++failures; std::cerr << "FAIL " << name << ": " << error.what() << '\n'; }
}
void rejects(const std::function<void()>& run, const std::string& message = {}) {
    try { run(); } catch (const Error& error) { expect(message.empty() || message == error.what()); return; }
    throw Error("预期操作失败");
}
struct Temporary {
    fs::path path = fs::temp_directory_path() / wide("Frog-features-test-" + uuid());
    Temporary() { fs::create_directories(path); }
    ~Temporary() { std::error_code error; fs::remove_all(path, error); }
};
Json folder(std::string name, Json children = Json::array()) { return {{"type", "folder"}, {"name", name}, {"children", children}}; }
Json bookmark(std::string url, std::string name = "标题") { return {{"type", "url"}, {"url", url}, {"name", name}, {"date_added", "11644473601000000"}}; }
std::string data(Json root) { return Json{{"roots", {{"bookmark_bar", root}}}}.dump(); }
void save(const fs::path& path, const std::string& bytes) { fs::create_directories(path.parent_path()); std::ofstream stream(path, std::ios::binary); stream << bytes; require(stream.good(), "无法写入测试数据"); }
}
int wmain() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED); ScopeExit cleanup{[] { CoUninitialize(); }};
    test("calculator-precedence-unary-parentheses-exponent", [] {
        expect(calculator::evaluate(" （2 + 3） * -4 / +2 + 1e2 ") == 90);
        expect(calculator::evaluate(".5 + 1. + 2E-1") == 1.7);
        expect(calculator::evaluate("--2") == 2);
        expect(calculator::evaluate("1\xE3\x80\x80+ 2") == 3);
    });
    test("calculator-format-twelve-digits", [] {
        expect(calculator::format(calculator::evaluate("0.1+0.2")) == "0.3");
        expect(calculator::format(1.23456789012345) == "1.23456789012");
        expect(calculator::format(-0.0) == "0"); expect(calculator::format(1e-9) == "1e-9");
        expect(calculator::format(std::numeric_limits<double>::infinity()) == "无法计算");
    });
    test("calculator-consumer-errors-and-length-boundary", [] {
        rejects([] { calculator::evaluate(" "); }, "请输入算式");
        rejects([] { calculator::evaluate("1/-0"); }, "不能除以 0");
        rejects([] { calculator::evaluate("(1+2"); }, "缺少右括号");
        rejects([] { calculator::evaluate("1)"); }, "多余的右括号");
        rejects([] { calculator::evaluate("1e+"); }, "算式不完整");
        rejects([] { calculator::evaluate("."); }, "算式不完整");
        rejects([] { calculator::evaluate("1+"); }, "算式不完整");
        rejects([] { calculator::evaluate("1e309"); }, "结果超出可计算范围");
        rejects([] { calculator::evaluate("1e308*10"); }, "结果超出可计算范围");
        rejects([] { calculator::evaluate("2^3"); }, "无法识别的字符 “^”");
        expect(calculator::evaluate(std::string(255, ' ') + "1") == 1);
        rejects([] { calculator::evaluate(std::string(256, ' ') + "1"); }, "算式过长");
        expect(calculator::filtered("abc（2+3）=中文") == "(2+3)");
        expect(calculator::filtered(std::string(300, '1')).size() == 256);
        expect(calculator::filtered("1́+2") == "+2");
        expect(calculator::filtered("1\r\n+2") == "1\r\n+2");
    });
    test("edge-nested-empty-groups-supported-roots-and-time", [] {
        auto json = Json{{"roots", {{"bookmark_bar", folder(" \r\n栏\t ", Json::array({bookmark(" https://example.com "), folder("子", Json::array({folder("空")})), bookmark("file:///tmp") }))}, {"other", folder("")}, {"synced", 42}}}};
        auto payload = edge::parse(json.dump()); auto result = edge::importPayload({}, payload);
        expect(result.summary.profiles == 1 && result.summary.groups == 4 && result.summary.inserted == 1 && result.summary.unsupported == 1);
        expect(result.document.groups[0].name == "栏" && result.document.groups[2].name == "栏 / 子 / 空" && result.document.groups[3].name == "其他收藏夹");
        expect(result.document.bookmarks[0].createdAt == 1000);
        expect(result.document.bookmarks[0].url == "https://example.com");
    });
    test("edge-exact-deduplication-and-existing-group-merge", [] {
        Document source; auto group = source.addGroup("栏"); source.upsert("", "原有", "https://example.com", group);
        auto original = source;
        auto payload = edge::parse(data(folder("栏", Json::array({bookmark("https://example.com"), bookmark("https://example.com/"), bookmark("https://example.com/"), bookmark("HTTPS://example.com/"), bookmark("javascript:bad")}))));
        auto result = edge::importPayload(source, payload);
        expect(source == original); expect(result.summary.groups == 0 && result.summary.inserted == 2 && result.summary.duplicates == 2 && result.summary.unsupported == 1);
        expect(result.document.bookmarks.size() == 3 && result.document.bookmarks[2].order == 2);
    });
    test("edge-invalid-node-and-size-boundaries", [] {
        for (auto bytes : {std::string("{"), std::string("{}"), std::string("{\"roots\":{}}"), data(folder("栏", Json::array({42}))), data(folder("栏", Json::array({Json{{"type", "url"}}}))), data(Json{{"type", "folder"}, {"children", nullptr}})}) rejects([&] { edge::parse(bytes); });
        auto bytes = data(folder("栏")); bytes.resize(edge::maximumBytes, ' ');
        expect(edge::parse(bytes).folders.size() == 1); bytes.push_back(' '); rejects([&] { edge::parse(bytes); });
    });
    test("edge-tail-truncation-graphemes-and-cleaning", [] {
        std::string longName = "discard"; for (int i = 0; i < 120; ++i) longName += "é";
        auto result = edge::importPayload({}, edge::parse(data(folder(longName, Json::array({bookmark("https://example.com", longName)})))));
        expect(characters(result.document.groups[0].name) == 120);
        expect(result.document.groups[0].name.starts_with("…") && result.document.groups[0].name.ends_with("é"));
        expect(result.document.bookmarks[0].title == result.document.groups[0].name);
    });
    test("edge-multiple-profiles-natural-order-and-atomic-failure", [] {
        Temporary temp; const auto bytes = data(folder("栏", Json::array({bookmark("https://example.com")})));
        save(temp.path / L"Default" / L"Bookmarks", bytes);
        save(temp.path / L"Profile 10" / L"Bookmarks", bytes);
        save(temp.path / L"Profile 2" / L"Bookmarks", bytes);
        save(temp.path / L"Guest Profile" / L"Bookmarks", "broken"); save(temp.path / L"System Profile" / L"Bookmarks", "broken");
        auto result = edge::importFrom({}, temp.path);
        expect(result.summary.profiles == 3 && result.summary.groups == 3 && result.summary.inserted == 1 && result.summary.duplicates == 2);
        expect(result.document.groups[0].name == "[Default] 栏" && result.document.groups[1].name == "[Profile 2] 栏" && result.document.groups[2].name == "[Profile 10] 栏");
        expect(edge::load(temp.path / L"Default").folders[0].name == "栏");
        expect(edge::load(temp.path / L"Default" / L"Bookmarks").profiles == 1);
        Document source = result.document; auto original = source;
        save(temp.path / L"Profile 10" / L"Bookmarks", "broken");
        rejects([&] { edge::importFrom(source, temp.path); }); expect(source == original);
        auto oversized = temp.path / L"oversized"; save(oversized, ""); fs::resize_file(oversized, edge::maximumBytes + 1); rejects([&] { edge::load(oversized); });
    });
    test("edge-import-order-overflow-and-invalid-timestamp", [] {
        Document source; auto id = source.addGroup("栏"); source.upsert("", "旧", "https://old.example", id);
        source.groups[0].order = INT64_MAX; source.bookmarks[0].order = INT64_MAX;
        EdgeImportPayload payload{{{"栏", {{"新", "https://new.example", -1}}}, {"空", {}}}, 1, 0};
        auto result = edge::importPayload(source, payload);
        expect(result.document.groups[0].order == 0 && result.document.groups[1].order == 1);
        expect(result.document.bookmarks[0].order == 0 && result.document.bookmarks[1].order == 1);
        expect(result.document.bookmarks[1].createdAt > 1700000000000.0);
    });
    return failures ? 1 : 0;
}
