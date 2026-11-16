// SPDX-License-Identifier: Apache-2.0
#pragma once
// A small JSON reader, enough for SingleStepTests' files: objects, arrays,
// integers, strings, true, false and null.

#include <cctype>
#include <cstdint>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace json {

struct Value {
    enum Kind { Null, Bool, Number, String, Array, Object } kind = Null;
    int64_t num = 0;
    std::string str;
    std::vector<Value> arr;
    std::map<std::string, Value> obj;

    const Value& operator[](const std::string& k) const {
        auto it = obj.find(k);
        if (it == obj.end()) throw std::runtime_error("json: no key " + k);
        return it->second;
    }
    const Value& operator[](size_t i) const { return arr.at(i); }
    bool has(const std::string& k) const { return obj.count(k) != 0; }
    int64_t i() const { return num; }
};

class Parser {
public:
    explicit Parser(const std::string& text) : s(text) {}
    Value parse() {
        Value v = value();
        ws();
        if (p != s.size()) fail("trailing data");
        return v;
    }

private:
    const std::string& s;
    size_t p = 0;

    [[noreturn]] void fail(const char* what) { throw std::runtime_error(std::string("json: ") + what + " at " + std::to_string(p)); }
    void ws() { while (p < s.size() && std::isspace(static_cast<unsigned char>(s[p]))) p++; }
    bool lit(const char* w) {
        size_t n = std::char_traits<char>::length(w);
        if (s.compare(p, n, w) != 0) return false;
        p += n;
        return true;
    }
    Value value() {
        ws();
        if (p >= s.size()) fail("unexpected end");
        Value v;
        char c = s[p];
        if (c == '{') {
            v.kind = Value::Object;
            p++;
            ws();
            if (s[p] == '}') { p++; return v; }
            for (;;) {
                ws();
                Value k = value();
                if (k.kind != Value::String) fail("key");
                ws();
                if (s[p++] != ':') fail("colon");
                v.obj[k.str] = value();
                ws();
                if (s[p] == ',') { p++; continue; }
                if (s[p] == '}') { p++; return v; }
                fail("object");
            }
        }
        if (c == '[') {
            v.kind = Value::Array;
            p++;
            ws();
            if (s[p] == ']') { p++; return v; }
            for (;;) {
                v.arr.push_back(value());
                ws();
                if (s[p] == ',') { p++; continue; }
                if (s[p] == ']') { p++; return v; }
                fail("array");
            }
        }
        if (c == '"') {
            v.kind = Value::String;
            p++;
            while (p < s.size() && s[p] != '"') {
                if (s[p] == '\\') p++;
                v.str += s[p++];
            }
            p++;
            return v;
        }
        if (lit("null")) return v;
        if (lit("true")) { v.kind = Value::Bool; v.num = 1; return v; }
        if (lit("false")) { v.kind = Value::Bool; return v; }
        if (c == '-' || std::isdigit(static_cast<unsigned char>(c))) {
            v.kind = Value::Number;
            size_t used = 0;
            v.num = std::stoll(s.substr(p, 24), &used);
            p += used;
            return v;
        }
        fail("value");
    }
};

inline Value parse(const std::string& text) { return Parser(text).parse(); }

} // namespace json
