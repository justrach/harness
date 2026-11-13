#include "include/CLuau.h"

#include "lua.h"
#include "luacode.h"
#include "lualib.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <limits>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr size_t kMaxSourceBytes = 64 * 1024;
constexpr size_t kMaxMemoryBytes = 16 * 1024 * 1024;
constexpr int64_t kCallBudgetNs = 20LL * 1000LL * 1000LL;
constexpr size_t kMaxNodes = 512;
constexpr size_t kMaxDepth = 24;
constexpr size_t kMaxTextBytes = 8 * 1024;
constexpr size_t kMaxSeries = 256;

struct MemTracker {
    size_t used = 0;
    size_t limit = kMaxMemoryBytes;
};

struct Budget {
    std::chrono::steady_clock::time_point start{};
    bool armed = false;
    bool timed_out = false;
};

enum class ExpectedKind {
    Click,
    Boolean,
    NumberRange,
};

struct Expected {
    ExpectedKind kind = ExpectedKind::Click;
    double min = 0.0;
    double max = 1.0;
};

struct Handler {
    int func_ref = LUA_NOREF;
    Expected expected;
};

enum class InputKind {
    None,
    Click,
    Boolean,
    Number,
};

struct Input {
    InputKind kind = InputKind::None;
    bool bool_val = false;
    double num_val = 0.0;
};

struct TreeStorage {
    CLuauTree c_tree{};
    std::vector<CLuauNode> nodes;
    std::vector<double> values;
    std::vector<const char *> chart_labels;
    std::vector<size_t> child_indices;
    std::deque<std::string> strings;

    const char *intern(std::string s) {
        strings.push_back(std::move(s));
        return strings.back().c_str();
    }
};

void write_err(char *buf, size_t cap, const char *msg) {
    if (!buf || cap == 0) return;
    if (!msg) msg = "visual execution failed";
    std::snprintf(buf, cap, "%s", msg);
}

int64_t elapsed_ns(const Budget &b) {
    auto now = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::nanoseconds>(now - b.start).count();
}

void *alloc_fn(void *ud, void *ptr, size_t osize, size_t nsize) {
    auto *tracker = static_cast<MemTracker *>(ud);
    if (nsize == 0) {
        if (ptr != nullptr) {
            tracker->used = tracker->used >= osize ? tracker->used - osize : 0;
            std::free(ptr);
        }
        return nullptr;
    }
    if (ptr == nullptr) {
        if (nsize > tracker->limit - tracker->used) return nullptr;
        void *p = std::malloc(nsize);
        if (!p) return nullptr;
        tracker->used += nsize;
        return p;
    }
    if (nsize > osize) {
        size_t delta = nsize - osize;
        if (delta > tracker->limit - tracker->used) return nullptr;
    }
    void *p = std::realloc(ptr, nsize);
    if (!p) return nullptr;
    tracker->used = (tracker->used >= osize ? tracker->used - osize : 0) + nsize;
    return p;
}

void interrupt_fn(lua_State *L, int /*gc*/) {
    lua_Callbacks *cb = lua_callbacks(L);
    auto *budget = static_cast<Budget *>(cb->userdata);
    if (!budget || !budget->armed) return;
    if (budget->timed_out || elapsed_ns(*budget) >= kCallBudgetNs) {
        budget->timed_out = true;
        luaL_error(L, "visual execution exceeded 20 ms");
    }
}

std::string pop_lua_error(lua_State *L) {
    size_t len = 0;
    const char *ptr = lua_tolstring(L, -1, &len);
    std::string out = (ptr && len > 0) ? std::string(ptr, len) : "visual execution failed";
    lua_settop(L, 0);
    return out;
}

const char *kind_name(CLuauNodeKind kind) {
    switch (kind) {
        case CLUAU_NODE_COLUMN: return "column";
        case CLUAU_NODE_ROW: return "row";
        case CLUAU_NODE_TEXT: return "text";
        case CLUAU_NODE_STAT: return "stat";
        case CLUAU_NODE_CHART: return "chart";
        case CLUAU_NODE_BUTTON: return "button";
        case CLUAU_NODE_TOGGLE: return "toggle";
        case CLUAU_NODE_SLIDER: return "slider";
        case CLUAU_NODE_RULE: return "rule";
    }
    return "unknown";
}

bool kind_from_name(const char *s, size_t len, CLuauNodeKind &out) {
    std::string_view sv(s, len);
    if (sv == "column") { out = CLUAU_NODE_COLUMN; return true; }
    if (sv == "row") { out = CLUAU_NODE_ROW; return true; }
    if (sv == "text") { out = CLUAU_NODE_TEXT; return true; }
    if (sv == "stat") { out = CLUAU_NODE_STAT; return true; }
    if (sv == "chart") { out = CLUAU_NODE_CHART; return true; }
    if (sv == "button") { out = CLUAU_NODE_BUTTON; return true; }
    if (sv == "toggle") { out = CLUAU_NODE_TOGGLE; return true; }
    if (sv == "slider") { out = CLUAU_NODE_SLIDER; return true; }
    if (sv == "rule") { out = CLUAU_NODE_RULE; return true; }
    return false;
}

const char *check_properties(lua_State *L, int table_idx, CLuauNodeKind kind, bool tagged) {
    if (lua_getmetatable(L, table_idx) != 0) {
        lua_settop(L, -2);
        return "unsupported visual property (styling is not supported)";
    }

    int abs_idx = table_idx < 0 ? lua_gettop(L) + table_idx + 1 : table_idx;
    size_t count = 0;
    lua_pushnil(L);
    while (lua_next(L, abs_idx) != 0) {
        count += 1;
        if (count > kMaxNodes + 8) {
            lua_settop(L, -3);
            return "too many visual properties";
        }
        int key_type = lua_type(L, -2);
        bool valid = false;
        if (key_type == LUA_TNUMBER && (kind == CLUAU_NODE_COLUMN || kind == CLUAU_NODE_ROW)) {
            double n = lua_tonumberx(L, -2, nullptr);
            if (std::isfinite(n) && std::floor(n) == n && n >= 1.0 && n <= static_cast<double>(kMaxNodes)) {
                valid = true;
            }
        } else if (key_type == LUA_TSTRING) {
            size_t klen = 0;
            const char *kptr = lua_tolstring(L, -2, &klen);
            if (kptr) {
                std::string_view kname(kptr, klen);
                if (tagged && kname == "__kind") {
                    valid = true;
                } else {
                    switch (kind) {
                        case CLUAU_NODE_COLUMN:
                        case CLUAU_NODE_ROW:
                        case CLUAU_NODE_RULE:
                            break;
                        case CLUAU_NODE_TEXT:
                            valid = (kname == "text");
                            break;
                        case CLUAU_NODE_STAT:
                            valid = (kname == "label" || kname == "value");
                            break;
                        case CLUAU_NODE_CHART:
                            valid = (kname == "label" || kname == "values" || kname == "labels");
                            break;
                        case CLUAU_NODE_BUTTON:
                            valid = (kname == "label" || kname == "onClick");
                            break;
                        case CLUAU_NODE_TOGGLE:
                            valid = (kname == "label" || kname == "value" || kname == "onChange");
                            break;
                        case CLUAU_NODE_SLIDER:
                            valid = (kname == "label" || kname == "value" || kname == "min" || kname == "max" || kname == "onChange");
                            break;
                    }
                }
            }
        }
        lua_settop(L, -2);
        if (!valid) {
            lua_settop(L, -2);
            return "unsupported visual property (styling is not supported)";
        }
    }
    return nullptr;
}

int ui_constructor(lua_State *L) {
    int raw_kind = lua_tointegerx(L, lua_upvalueindex(1), nullptr);
    auto kind = static_cast<CLuauNodeKind>(raw_kind);

    if (lua_gettop(L) < 1) {
        luaL_error(L, "visual constructors require a property table (or a text string)");
    }

    int arg_type = lua_type(L, 1);
    if (kind == CLUAU_NODE_TEXT && arg_type == LUA_TSTRING) {
        lua_createtable(L, 0, 2);
        lua_pushvalue(L, 1);
        lua_rawsetfield(L, -2, "text");
        const char *kname = kind_name(kind);
        lua_pushlstring(L, kname, std::strlen(kname));
        lua_rawsetfield(L, -2, "__kind");
        return 1;
    }

    if (arg_type != LUA_TTABLE) {
        luaL_error(L, "visual constructors require a property table (or a text string)");
    }

    if (const char *err = check_properties(L, 1, kind, false)) {
        luaL_error(L, "%s", err);
    }

    const char *kname = kind_name(kind);
    lua_pushlstring(L, kname, std::strlen(kname));
    lua_rawsetfield(L, 1, "__kind");
    lua_settop(L, 1);
    return 1;
}

void open_safe_libs(lua_State *L) {
    struct Lib { const char *name; lua_CFunction fn; };
    const Lib libs[] = {
        {"", luaopen_base},
        {"table", luaopen_table},
        {"string", luaopen_string},
        {"math", luaopen_math},
        {"utf8", luaopen_utf8},
    };
    for (const auto &lib : libs) {
        lua_pushcclosurek(L, lib.fn, lib.name, 0, nullptr);
        lua_pushstring(L, lib.name);
        lua_call(L, 1, 0);
    }
    const char *disabled[] = {
        "print", "warn", "require", "load", "loadstring",
        "loadfile", "dofile", "collectgarbage", "getfenv", "setfenv", "newproxy",
    };
    for (const char *name : disabled) {
        lua_pushnil(L);
        lua_rawsetfield(L, LUA_GLOBALSINDEX, name);
    }
}

void install_ui(lua_State *L) {
    const CLuauNodeKind kinds[] = {
        CLUAU_NODE_COLUMN, CLUAU_NODE_ROW, CLUAU_NODE_TEXT,
        CLUAU_NODE_STAT, CLUAU_NODE_CHART, CLUAU_NODE_BUTTON,
        CLUAU_NODE_TOGGLE, CLUAU_NODE_SLIDER, CLUAU_NODE_RULE,
    };
    lua_createtable(L, 0, 9);
    for (CLuauNodeKind k : kinds) {
        const char *name = kind_name(k);
        lua_pushinteger(L, static_cast<int>(k));
        lua_pushcclosurek(L, ui_constructor, name, 1, nullptr);
        lua_rawsetfield(L, -2, name);
    }
    lua_setreadonly(L, -1, 1);
    lua_rawsetfield(L, LUA_GLOBALSINDEX, "ui");
}

std::string format_number(double n) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.15g", n);
    if (std::strcmp(buf, "-0") == 0) return "0";
    return std::string(buf);
}

} // namespace

struct CLuauSandbox {
    MemTracker tracker;
    Budget budget;
    lua_State *L = nullptr;
    int renderer_ref = LUA_NOREF;
    std::unordered_map<uint64_t, Handler> handlers;
    uint64_t next_id = 1;

    ~CLuauSandbox() {
        if (L) {
            if (renderer_ref != LUA_NOREF) {
                lua_unref(L, renderer_ref);
                renderer_ref = LUA_NOREF;
            }
            clear_handlers();
            lua_close(L);
            L = nullptr;
        }
    }

    void clear_handlers() {
        if (!L) {
            handlers.clear();
            return;
        }
        for (auto &kv : handlers) {
            lua_unref(L, kv.second.func_ref);
        }
        handlers.clear();
    }

    void arm_budget() {
        budget.start = std::chrono::steady_clock::now();
        budget.armed = true;
        budget.timed_out = false;
    }

    void disarm_budget() {
        budget.armed = false;
    }

    const char *check_budget() const {
        if (budget.timed_out || elapsed_ns(budget) >= kCallBudgetNs) {
            return "visual execution exceeded 20 ms";
        }
        return nullptr;
    }
};

namespace {

class Parser {
public:
    Parser(CLuauSandbox *sb, TreeStorage *storage)
        : sb_(sb), storage_(storage) {}

    bool parse_root(lua_State *L, int idx) {
        size_t out_idx = 0;
        if (!parse_node(L, idx, 1, out_idx)) {
            cleanup_on_error(L);
            return false;
        }
        return true;
    }

    void cleanup_on_error(lua_State *L) {
        for (auto &kv : pending_handlers_) {
            lua_unref(L, kv.second.func_ref);
        }
        pending_handlers_.clear();
    }

    std::unordered_map<uint64_t, Handler> take_handlers() {
        return std::move(pending_handlers_);
    }

    const std::string &error() const { return err_msg_; }

private:
    bool fail(const char *msg) {
        err_msg_ = msg;
        return false;
    }

    bool parse_node(lua_State *L, int idx, size_t depth, size_t &out_node_idx) {
        if (const char *bmsg = sb_->check_budget()) return fail(bmsg);
        if (depth > kMaxDepth) return fail("visual tree exceeds maximum depth");
        node_count_ += 1;
        if (node_count_ > kMaxNodes) return fail("visual tree exceeds maximum node count");

        int abs_idx = idx < 0 ? lua_gettop(L) + idx + 1 : idx;
        if (lua_type(L, abs_idx) != LUA_TTABLE) return fail("visual nodes must be tables");
        if (lua_getmetatable(L, abs_idx) != 0) {
            lua_settop(L, -2);
            return fail("unsupported visual property (styling is not supported)");
        }

        lua_rawgetfield(L, abs_idx, "__kind");
        if (lua_type(L, -1) != LUA_TSTRING) {
            lua_settop(L, -2);
            return fail("unsupported visual node kind");
        }
        size_t klen = 0;
        const char *kptr = lua_tolstring(L, -1, &klen);
        CLuauNodeKind kind{};
        bool ok_kind = kptr && kind_from_name(kptr, klen, kind);
        lua_settop(L, -2);
        if (!ok_kind) return fail("unsupported visual node kind");

        if (const char *perr = check_properties(L, abs_idx, kind, true)) {
            return fail(perr);
        }

        out_node_idx = storage_->nodes.size();
        storage_->nodes.push_back(CLuauNode{});
        CLuauNode node{};
        node.kind = kind;
        node.text = storage_->intern("");

        switch (kind) {
            case CLUAU_NODE_COLUMN:
            case CLUAU_NODE_ROW: {
                std::vector<size_t> children;
                if (!parse_children(L, abs_idx, depth, children)) return false;
                node.children_offset = storage_->child_indices.size();
                node.children_count = children.size();
                storage_->child_indices.insert(storage_->child_indices.end(), children.begin(), children.end());
                break;
            }
            case CLUAU_NODE_TEXT: {
                std::string text;
                if (!read_text_field(L, abs_idx, "text", text)) return false;
                node.text = storage_->intern(std::move(text));
                break;
            }
            case CLUAU_NODE_STAT: {
                std::string label, val;
                if (!read_label(L, abs_idx, label)) return false;
                if (!read_text_field(L, abs_idx, "value", val)) return false;
                if (!label.empty()) {
                    text_bytes_ += 2;
                    if (text_bytes_ > kMaxTextBytes) return fail("visual text exceeds 8 KiB");
                    node.text = storage_->intern(label + ": " + val);
                } else {
                    node.text = storage_->intern(std::move(val));
                }
                break;
            }
            case CLUAU_NODE_CHART: {
                if (!parse_chart(L, abs_idx, node)) return false;
                break;
            }
            case CLUAU_NODE_BUTTON: {
                std::string label;
                if (!read_label(L, abs_idx, label)) return false;
                node.text = storage_->intern(std::move(label));
                uint64_t hid = 0;
                bool has_h = false;
                if (!read_handler(L, abs_idx, "onClick", Expected{ExpectedKind::Click, 0, 1}, hid, has_h)) return false;
                node.handler_id = hid;
                node.has_handler = has_h ? 1 : 0;
                break;
            }
            case CLUAU_NODE_TOGGLE: {
                std::string label;
                if (!read_label(L, abs_idx, label)) return false;
                bool bval = false;
                if (!read_bool(L, abs_idx, "value", bval)) return false;
                uint64_t hid = 0;
                bool has_h = false;
                if (!read_handler(L, abs_idx, "onChange", Expected{ExpectedKind::Boolean, 0, 1}, hid, has_h)) return false;
                node.text = storage_->intern(std::move(label));
                node.value = bval ? 1.0 : 0.0;
                node.handler_id = hid;
                node.has_handler = has_h ? 1 : 0;
                break;
            }
            case CLUAU_NODE_SLIDER: {
                if (!parse_slider(L, abs_idx, node)) return false;
                break;
            }
            case CLUAU_NODE_RULE:
                break;
        }

        storage_->nodes[out_node_idx] = node;
        return true;
    }

    bool parse_children(lua_State *L, int abs_idx, size_t depth, std::vector<size_t> &out) {
        size_t max_ix = 0;
        size_t count = 0;
        lua_pushnil(L);
        while (lua_next(L, abs_idx) != 0) {
            if (lua_type(L, -2) == LUA_TNUMBER) {
                double n = lua_tonumberx(L, -2, nullptr);
                auto ix = static_cast<size_t>(n);
                count += 1;
                if (ix > max_ix) max_ix = ix;
            }
            lua_settop(L, -2);
        }
        if (count != max_ix) return fail("visual child list cannot contain holes");
        if (count == 0) return true;

        out.reserve(count);
        for (size_t i = 1; i <= count; ++i) {
            lua_rawgeti(L, abs_idx, static_cast<int>(i));
            size_t child_idx = 0;
            bool ok = parse_node(L, -1, depth + 1, child_idx);
            lua_settop(L, -2);
            if (!ok) return false;
            out.push_back(child_idx);
        }
        return true;
    }

    bool parse_chart(lua_State *L, int abs_idx, CLuauNode &node) {
        std::string label;
        if (!read_label(L, abs_idx, label)) return false;
        node.text = storage_->intern(std::move(label));

        lua_rawgetfield(L, abs_idx, "values");
        if (lua_type(L, -1) != LUA_TTABLE) {
            lua_settop(L, -2);
            return fail("chart values must be a table");
        }
        int vals_idx = lua_gettop(L);
        std::vector<double> vals;
        bool vals_ok = parse_values_seq(L, vals_idx, vals);
        lua_settop(L, -2);
        if (!vals_ok) return false;

        std::vector<std::string> labels;
        lua_rawgetfield(L, abs_idx, "labels");
        if (lua_type(L, -1) != LUA_TNIL) {
            if (lua_type(L, -1) != LUA_TTABLE) {
                lua_settop(L, -2);
                return fail("chart labels must be a table");
            }
            int lbl_idx = lua_gettop(L);
            bool lbl_ok = parse_labels_seq(L, lbl_idx, vals.size(), labels);
            lua_settop(L, -2);
            if (!lbl_ok) return false;
        } else {
            lua_settop(L, -2);
        }

        node.values_offset = storage_->values.size();
        node.values_count = vals.size();
        storage_->values.insert(storage_->values.end(), vals.begin(), vals.end());

        node.labels_offset = storage_->chart_labels.size();
        node.labels_count = labels.size();
        for (auto &s : labels) {
            storage_->chart_labels.push_back(storage_->intern(std::move(s)));
        }
        return true;
    }

    bool parse_values_seq(lua_State *L, int tbl_idx, std::vector<double> &out) {
        if (lua_getmetatable(L, tbl_idx) != 0) {
            lua_settop(L, -2);
            return fail("chart values must be a plain sequence");
        }
        size_t count = 0;
        size_t max_ix = 0;
        lua_pushnil(L);
        while (lua_next(L, tbl_idx) != 0) {
            count += 1;
            if (count > kMaxSeries) {
                lua_settop(L, -3);
                return fail("chart series exceeds 256 values");
            }
            if (lua_type(L, -2) != LUA_TNUMBER) {
                lua_settop(L, -3);
                return fail("chart values must be a sequence without extra keys");
            }
            double k = lua_tonumberx(L, -2, nullptr);
            if (!std::isfinite(k) || std::floor(k) != k || k < 1.0 || k > static_cast<double>(kMaxSeries)) {
                lua_settop(L, -3);
                return fail("chart values must be a sequence");
            }
            auto ix = static_cast<size_t>(k);
            if (ix > max_ix) max_ix = ix;
            lua_settop(L, -2);
        }
        if (count != max_ix) return fail("chart values sequence cannot contain holes");
        series_count_ += count;
        if (series_count_ > kMaxSeries) return fail("chart series exceeds 256 values");

        out.reserve(count);
        for (size_t i = 1; i <= count; ++i) {
            lua_rawgeti(L, tbl_idx, static_cast<int>(i));
            int isnum = 0;
            double n = lua_tonumberx(L, -1, &isnum);
            int t = lua_type(L, -1);
            lua_settop(L, -2);
            if (t != LUA_TNUMBER || isnum == 0 || !std::isfinite(n)) {
                return fail("chart values must be finite numbers");
            }
            out.push_back(n);
        }
        return true;
    }

    bool parse_labels_seq(lua_State *L, int tbl_idx, size_t expected_len, std::vector<std::string> &out) {
        if (lua_getmetatable(L, tbl_idx) != 0) {
            lua_settop(L, -2);
            return fail("chart labels must be a plain sequence");
        }
        size_t count = 0;
        size_t max_ix = 0;
        lua_pushnil(L);
        while (lua_next(L, tbl_idx) != 0) {
            count += 1;
            if (count > kMaxSeries) {
                lua_settop(L, -3);
                return fail("chart labels exceed 256 items");
            }
            if (lua_type(L, -2) != LUA_TNUMBER) {
                lua_settop(L, -3);
                return fail("chart labels must be a sequence");
            }
            double k = lua_tonumberx(L, -2, nullptr);
            if (!std::isfinite(k) || std::floor(k) != k || k < 1.0 || k > static_cast<double>(kMaxSeries)) {
                lua_settop(L, -3);
                return fail("chart labels must be a sequence");
            }
            auto ix = static_cast<size_t>(k);
            if (ix > max_ix) max_ix = ix;
            lua_settop(L, -2);
        }
        if (count != max_ix) return fail("chart labels cannot contain holes");
        if (count != expected_len) return fail("chart labels length must match values length");

        out.reserve(count);
        for (size_t i = 1; i <= count; ++i) {
            lua_rawgeti(L, tbl_idx, static_cast<int>(i));
            std::string s;
            bool ok = read_text_at(L, -1, s);
            lua_settop(L, -2);
            if (!ok) return false;
            out.push_back(std::move(s));
        }
        return true;
    }

    bool parse_slider(lua_State *L, int abs_idx, CLuauNode &node) {
        std::string label;
        if (!read_label(L, abs_idx, label)) return false;
        double min_val = 0, max_val = 0, val = 0;
        if (!read_required_finite(L, abs_idx, "min", min_val)) return false;
        if (!read_required_finite(L, abs_idx, "max", max_val)) return false;
        if (!read_required_finite(L, abs_idx, "value", val)) return false;
        if (min_val > max_val || val < min_val || val > max_val) {
            return fail("invalid slider range or value");
        }
        uint64_t hid = 0;
        bool has_h = false;
        if (!read_handler(L, abs_idx, "onChange", Expected{ExpectedKind::NumberRange, min_val, max_val}, hid, has_h)) {
            return false;
        }
        node.text = storage_->intern(std::move(label));
        node.value = val;
        node.min_value = min_val;
        node.max_value = max_val;
        node.handler_id = hid;
        node.has_handler = has_h ? 1 : 0;
        return true;
    }

    bool read_text_field(lua_State *L, int abs_idx, const char *field, std::string &out) {
        lua_rawgetfield(L, abs_idx, field);
        bool ok = read_text_at(L, -1, out);
        lua_settop(L, -2);
        return ok;
    }

    bool read_label(lua_State *L, int abs_idx, std::string &out) {
        lua_rawgetfield(L, abs_idx, "label");
        if (lua_type(L, -1) == LUA_TNIL) {
            lua_settop(L, -2);
            out.clear();
            return true;
        }
        bool ok = read_text_at(L, -1, out);
        lua_settop(L, -2);
        return ok;
    }

    bool read_text_at(lua_State *L, int idx, std::string &out) {
        int t = lua_type(L, idx);
        if (t == LUA_TSTRING) {
            size_t len = 0;
            const char *ptr = lua_tolstring(L, idx, &len);
            if (len > kMaxTextBytes || text_bytes_ + len > kMaxTextBytes) {
                return fail("visual text exceeds 8 KiB");
            }
            out.assign(ptr ? ptr : "", len);
        } else if (t == LUA_TNUMBER) {
            double n = lua_tonumberx(L, idx, nullptr);
            if (!std::isfinite(n)) return fail("expected visual text or a finite number");
            std::string formatted = format_number(n);
            if (text_bytes_ + formatted.size() > kMaxTextBytes) {
                return fail("visual text exceeds 8 KiB");
            }
            out = std::move(formatted);
        } else {
            return fail("expected visual text or a finite number");
        }
        text_bytes_ += out.size();
        return true;
    }

    bool read_bool(lua_State *L, int abs_idx, const char *field, bool &out) {
        lua_rawgetfield(L, abs_idx, field);
        int t = lua_type(L, -1);
        int b = lua_toboolean(L, -1);
        lua_settop(L, -2);
        if (t != LUA_TBOOLEAN) return fail("toggle value must be a boolean");
        out = (b != 0);
        return true;
    }

    bool read_required_finite(lua_State *L, int abs_idx, const char *field, double &out) {
        lua_rawgetfield(L, abs_idx, field);
        int t = lua_type(L, -1);
        double n = lua_tonumberx(L, -1, nullptr);
        lua_settop(L, -2);
        if (t != LUA_TNUMBER || !std::isfinite(n)) return fail("expected a finite number");
        out = n;
        return true;
    }

    bool read_handler(lua_State *L, int abs_idx, const char *field, Expected expected, uint64_t &out_id, bool &out_has) {
        lua_rawgetfield(L, abs_idx, field);
        int t = lua_type(L, -1);
        if (t == LUA_TNIL) {
            lua_settop(L, -2);
            out_id = 0;
            out_has = false;
            return true;
        }
        if (t != LUA_TFUNCTION) {
            lua_settop(L, -2);
            return fail("visual handler must be a function");
        }
        uint64_t id = sb_->next_id;
        if (id == std::numeric_limits<uint64_t>::max()) {
            lua_settop(L, -2);
            return fail("visual handler ids exhausted");
        }
        sb_->next_id = id + 1;
        int ref = lua_ref(L, -1);
        lua_settop(L, -2);
        pending_handlers_.emplace(id, Handler{ref, expected});
        out_id = id;
        out_has = true;
        return true;
    }

    CLuauSandbox *sb_;
    TreeStorage *storage_;
    size_t node_count_ = 0;
    size_t text_bytes_ = 0;
    size_t series_count_ = 0;
    std::unordered_map<uint64_t, Handler> pending_handlers_;
    std::string err_msg_;
};

bool matches_expected(const Expected &exp, const Input &input) {
    switch (exp.kind) {
        case ExpectedKind::Click:
            return input.kind == InputKind::Click;
        case ExpectedKind::Boolean:
            return input.kind == InputKind::Boolean;
        case ExpectedKind::NumberRange:
            return input.kind == InputKind::Number &&
                   std::isfinite(input.num_val) &&
                   input.num_val >= exp.min &&
                   input.num_val <= exp.max;
    }
    return false;
}

CLuauTree *execute_sandbox(CLuauSandbox *sb, bool has_event_fn, const Input &input, char *err_buf, size_t err_cap) {
    lua_State *L = sb->L;
    sb->arm_budget();

    struct Cleanup {
        CLuauSandbox *sb;
        lua_State *L;
        ~Cleanup() {
            sb->disarm_budget();
            lua_settop(L, 0);
        }
    } cleanup{sb, L};

    if (has_event_fn) {
        int nargs = 0;
        if (input.kind == InputKind::Boolean) {
            lua_pushboolean(L, input.bool_val ? 1 : 0);
            nargs = 1;
        } else if (input.kind == InputKind::Number) {
            lua_pushnumber(L, input.num_val);
            nargs = 1;
        }
        if (lua_pcall(L, nargs, 0, 0) != 0) {
            if (sb->budget.timed_out) {
                write_err(err_buf, err_cap, "visual execution exceeded 20 ms");
            } else {
                std::string msg = pop_lua_error(L);
                write_err(err_buf, err_cap, msg.c_str());
            }
            return nullptr;
        }
        if (const char *bmsg = sb->check_budget()) {
            write_err(err_buf, err_cap, bmsg);
            return nullptr;
        }
    }

    lua_getref(L, sb->renderer_ref);
    if (lua_pcall(L, 0, 1, 0) != 0) {
        if (sb->budget.timed_out) {
            write_err(err_buf, err_cap, "visual execution exceeded 20 ms");
        } else {
            std::string msg = pop_lua_error(L);
            write_err(err_buf, err_cap, msg.c_str());
        }
        return nullptr;
    }
    if (const char *bmsg = sb->check_budget()) {
        write_err(err_buf, err_cap, bmsg);
        return nullptr;
    }

    auto storage = std::make_unique<TreeStorage>();
    Parser parser(sb, storage.get());
    if (!parser.parse_root(L, -1)) {
        write_err(err_buf, err_cap, parser.error().c_str());
        return nullptr;
    }
    if (const char *bmsg = sb->check_budget()) {
        parser.cleanup_on_error(L);
        write_err(err_buf, err_cap, bmsg);
        return nullptr;
    }

    sb->handlers = parser.take_handlers();

    storage->c_tree.nodes = storage->nodes.empty() ? nullptr : storage->nodes.data();
    storage->c_tree.nodes_count = storage->nodes.size();
    storage->c_tree.values = storage->values.empty() ? nullptr : storage->values.data();
    storage->c_tree.values_count = storage->values.size();
    storage->c_tree.chart_labels = storage->chart_labels.empty() ? nullptr : storage->chart_labels.data();
    storage->c_tree.chart_labels_count = storage->chart_labels.size();
    storage->c_tree.child_indices = storage->child_indices.empty() ? nullptr : storage->child_indices.data();
    storage->c_tree.child_indices_count = storage->child_indices.size();

    return reinterpret_cast<CLuauTree *>(storage.release());
}

CLuauTree *call_handler(CLuauSandbox *sb, uint64_t handler_id, const Input &input, char *err_buf, size_t err_cap) {
    if (!sb || !sb->L) {
        write_err(err_buf, err_cap, "visual sandbox unavailable");
        return nullptr;
    }
    auto it = sb->handlers.find(handler_id);
    if (it == sb->handlers.end()) {
        write_err(err_buf, err_cap, "unknown or stale visual handler");
        return nullptr;
    }
    if (!matches_expected(it->second.expected, input)) {
        write_err(err_buf, err_cap, "visual handler input has the wrong type or is outside its range");
        return nullptr;
    }
    lua_getref(sb->L, it->second.func_ref);
    sb->clear_handlers();
    return execute_sandbox(sb, true, input, err_buf, err_cap);
}

} // namespace

extern "C" {

CLuauSandbox *cluau_sandbox_create(const char *source, size_t source_len, char *err_buf, size_t err_cap) {
    if (!source && source_len > 0) {
        write_err(err_buf, err_cap, "invalid visual source");
        return nullptr;
    }
    if (source_len > kMaxSourceBytes) {
        write_err(err_buf, err_cap, "visual source exceeds 64 KiB");
        return nullptr;
    }

    auto sb = std::make_unique<CLuauSandbox>();
    lua_State *L = lua_newstate(alloc_fn, &sb->tracker);
    if (!L) {
        write_err(err_buf, err_cap, "not enough memory");
        return nullptr;
    }
    sb->L = L;

    open_safe_libs(L);
    install_ui(L);
    luaL_sandbox(L);
    luaL_sandboxthread(L);

    lua_Callbacks *cb = lua_callbacks(L);
    cb->userdata = &sb->budget;
    cb->interrupt = interrupt_fn;

    sb->arm_budget();
    lua_CompileOptions opts{};
    opts.optimizationLevel = 1;
    opts.debugLevel = 1;
    size_t bc_size = 0;
    char *bc = luau_compile(source ? source : "", source_len, &opts, &bc_size);
    if (!bc) {
        sb->disarm_budget();
        write_err(err_buf, err_cap, "visual compilation failed");
        return nullptr;
    }
    int load_rc = luau_load(L, "=visual", bc, bc_size, 0);
    std::free(bc);
    if (load_rc != 0) {
        std::string msg = pop_lua_error(L);
        sb->disarm_budget();
        write_err(err_buf, err_cap, msg.c_str());
        return nullptr;
    }

    if (lua_pcall(L, 0, 1, 0) != 0) {
        if (sb->budget.timed_out) {
            lua_settop(L, 0);
            sb->disarm_budget();
            write_err(err_buf, err_cap, "visual execution exceeded 20 ms");
        } else {
            std::string msg = pop_lua_error(L);
            sb->disarm_budget();
            write_err(err_buf, err_cap, msg.c_str());
        }
        return nullptr;
    }

    if (const char *bmsg = sb->check_budget()) {
        sb->disarm_budget();
        write_err(err_buf, err_cap, bmsg);
        return nullptr;
    }
    sb->disarm_budget();

    if (lua_type(L, -1) != LUA_TFUNCTION) {
        lua_settop(L, 0);
        write_err(err_buf, err_cap, "visual script must return a render function");
        return nullptr;
    }
    sb->renderer_ref = lua_ref(L, -1);
    lua_settop(L, 0);
    return sb.release();
}

void cluau_sandbox_destroy(CLuauSandbox *sandbox) {
    delete sandbox;
}

size_t cluau_sandbox_memory_used(const CLuauSandbox *sandbox) {
    return sandbox ? sandbox->tracker.used : 0;
}

void cluau_sandbox_gc(CLuauSandbox *sandbox) {
    if (sandbox && sandbox->L) {
        lua_gc(sandbox->L, LUA_GCCOLLECT, 0);
    }
}

CLuauTree *cluau_sandbox_render(CLuauSandbox *sandbox, char *err_buf, size_t err_cap) {
    if (!sandbox || !sandbox->L) {
        write_err(err_buf, err_cap, "visual sandbox unavailable");
        return nullptr;
    }
    sandbox->clear_handlers();
    return execute_sandbox(sandbox, false, Input{}, err_buf, err_cap);
}

CLuauTree *cluau_sandbox_call_click(CLuauSandbox *sandbox, uint64_t handler_id, char *err_buf, size_t err_cap) {
    return call_handler(sandbox, handler_id, Input{InputKind::Click, false, 0.0}, err_buf, err_cap);
}

CLuauTree *cluau_sandbox_call_bool(CLuauSandbox *sandbox, uint64_t handler_id, int value, char *err_buf, size_t err_cap) {
    return call_handler(sandbox, handler_id, Input{InputKind::Boolean, value != 0, 0.0}, err_buf, err_cap);
}

CLuauTree *cluau_sandbox_call_number(CLuauSandbox *sandbox, uint64_t handler_id, double value, char *err_buf, size_t err_cap) {
    return call_handler(sandbox, handler_id, Input{InputKind::Number, false, value}, err_buf, err_cap);
}

void cluau_tree_free(CLuauTree *tree) {
    if (!tree) return;
    delete reinterpret_cast<TreeStorage *>(tree);
}

} // extern "C"
