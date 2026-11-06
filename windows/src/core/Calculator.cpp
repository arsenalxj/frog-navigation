#include "Calculator.h"
#include "Util.h"
#include <charconv>
#include <cmath>
#include <icu.h>
#include <limits>
#include <cstdlib>
#include <locale.h>
#include <string_view>

namespace frog::calculator {
namespace {
bool space(wchar_t c) { return u_isUWhiteSpace(c) != 0; }
bool digit(wchar_t c) { return c >= L'0' && c <= L'9'; }
class Parser {
    const std::wstring& text;
    size_t index = 0;
    void skip() { while (index < text.size() && space(text[index])) ++index; }
    bool take(wchar_t c) { skip(); if (index < text.size() && text[index] == c) { ++index; return true; } return false; }
    [[noreturn]] void unexpected() const {
        if (index == text.size()) throw Error("算式不完整");
        if (text[index] == L')') throw Error("多余的右括号");
        if (std::wstring_view(L"+-*/").find(text[index]) != std::wstring_view::npos) throw Error("算式不完整");
        size_t count = text[index] >= 0xd800 && text[index] <= 0xdbff && index + 1 < text.size() ? 2 : 1;
        throw Error("无法识别的字符 “" + utf8(text.substr(index, count)) + "”");
    }
    double expression() {
        double value = term();
        for (;;) { if (take(L'+')) value += term(); else if (take(L'-')) value -= term(); else return value; }
    }
    double term() {
        double value = unary();
        for (;;) {
            if (take(L'*')) value *= unary();
            else if (take(L'/')) { double right = unary(); require(right != 0, "不能除以 0"); value /= right; }
            else return value;
        }
    }
    double unary() { if (take(L'+')) return unary(); if (take(L'-')) return -unary(); return primary(); }
    double primary() {
        if (take(L'(')) { double value = expression(); require(take(L')'), "缺少右括号"); return value; }
        skip(); const size_t start = index; bool dot = false;
        while (index < text.size()) {
            if (digit(text[index])) ++index;
            else if (text[index] == L'.' && !dot) { dot = true; ++index; }
            else break;
        }
        if (index < text.size() && (text[index] == L'e' || text[index] == L'E')) {
            ++index;
            if (index < text.size() && (text[index] == L'+' || text[index] == L'-')) ++index;
            const size_t startExponent = index;
            while (index < text.size() && digit(text[index])) ++index;
            require(index > startExponent, "算式不完整");
        }
        if (index == start) unexpected();
        const auto literal = utf8(text.substr(start, index - start));
        // The C locale is explicit: decimal input must not depend on the user's region.
        char* end = nullptr;
        struct NumericLocale {
            _locale_t value = _create_locale(LC_NUMERIC, "C");
            ~NumericLocale() { _free_locale(value); }
        };
        static const NumericLocale locale;
        require(locale.value != nullptr, "无法初始化数字格式");
        const double value = _strtod_l(literal.c_str(), &end, locale.value);
        require(end == literal.data() + literal.size() && end != literal.data(), "算式不完整");
        return value;
    }
public:
    explicit Parser(const std::wstring& value) : text(value) {}
    double run() {
        skip(); require(index != text.size(), "请输入算式");
        double value = expression(); skip(); if (index != text.size()) unexpected();
        require(std::isfinite(value), "结果超出可计算范围"); return value;
    }
};
}
std::string normalize(const std::string& source) {
    auto text = wide(source);
    for (auto& c : text) {
        if (c >= L'０' && c <= L'９') c = static_cast<wchar_t>(L'0' + (c - L'０'));
        else switch (c) {
        case L'×': case L'＊': c = L'*'; break;
        case L'÷': case L'／': c = L'/'; break;
        case L'＋': c = L'+'; break;
        case L'－': c = L'-'; break;
        case L'（': c = L'('; break;
        case L'）': c = L')'; break;
        case L'．': c = L'.'; break;
        case L'ｅ': c = L'e'; break;
        case L'Ｅ': c = L'E'; break;
        }
    }
    return utf8(text);
}
std::string format(double value) {
    if (!std::isfinite(value)) return "无法计算";
    if (value == 0) return "0";
    char buffer[64]; auto converted = std::to_chars(buffer, buffer + sizeof(buffer), value, std::chars_format::general, 12);
    require(converted.ec == std::errc{}, "无法格式化计算结果");
    std::string result(buffer, converted.ptr);
    auto exponent = result.find('e');
    if (exponent != std::string::npos && exponent + 3 < result.size() && result[exponent + 2] == '0') result.erase(exponent + 2, 1);
    return result;
}
double evaluate(const std::string& source) {
    auto normalized = normalize(source); require(characters(normalized) <= maxLength, "算式过长");
    auto text = wide(normalized); return Parser(text).run();
}
}
