//! 极简 TOML 读取器：只支持 leantty.toml 实际用到的语法子集。
//!
//! 支持：
//!   - `[section]` / `[section.sub]` 表头
//!   - `key = "string"`、`key = 12`、`key = 1.5`、`key = true`
//!   - 内联表 `key = { a = 1, b = "x" }`（展开成 `key.a` / `key.b`）
//!   - 数组 `key = [ ... ]`：记录为 `.array`，元素不展开（调用方按需忽略）
//!   - `#` 注释、行尾注释（字符串外的 `#`）
//! 不支持：多行字符串、日期、点号键、数组表 `[[x]]`、转义 `\u`。
//! 解析失败只影响该行（跳过并计数），不 panic。

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    array,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const ParseResult = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// 跳过的行数（语法不认识或值非法）。
    skipped: usize = 0,

    pub fn deinit(self: *ParseResult, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
    }

    pub fn get(self: *const ParseResult, key: []const u8) ?Value {
        // 后出现的覆盖先出现的（与 TOML 直觉一致）
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.entries.items[i].key, key))
                return self.entries.items[i].value;
        }
        return null;
    }

    pub fn set(self: *ParseResult, alloc: std.mem.Allocator, key: []const u8, value: Value) !void {
        try self.entries.append(alloc, .{ .key = key, .value = value });
    }
};

fn trimComment(line: []const u8) []const u8 {
    var in_str = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"' and (i == 0 or line[i - 1] != '\\')) in_str = !in_str;
        if (c == '#' and !in_str) return line[0..i];
    }
    return line;
}

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return v;
}

/// 解析单个值；返回 null 表示无法识别。
pub fn parseValue(text: []const u8) ?Value {
    const v = std.mem.trim(u8, text, " \t");
    if (v.len == 0) return null;
    if (v[0] == '"') return .{ .string = unquote(v) };
    if (std.mem.eql(u8, v, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, v, "false")) return .{ .boolean = false };
    if (v[0] == '[') return .array;
    if (v[0] == '{') return null; // 内联表由调用方展开
    if (std.mem.indexOfAny(u8, v, ".eE") != null) {
        if (std.fmt.parseFloat(f64, v)) |f| return .{ .float = f } else |_| return null;
    }
    if (std.fmt.parseInt(i64, v, 10)) |n| return .{ .int = n } else |_| return null;
}

/// 把内联表 `{ a = 1, b = "x" }` 展开成 `prefix.a` / `prefix.b`。
fn parseInlineTable(res: *ParseResult, alloc: std.mem.Allocator, prefix: []const u8, body: []const u8) !void {
    var inner = body;
    if (inner.len >= 2 and inner[0] == '{' and inner[inner.len - 1] == '}') inner = inner[1 .. inner.len - 1];
    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse {
            res.skipped += 1;
            continue;
        };
        const k = std.mem.trim(u8, part[0..eq], " \t");
        const v = std.mem.trim(u8, part[eq + 1 ..], " \t");
        const full = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ prefix, k });
        if (v.len > 0 and v[0] == '{') {
            try parseInlineTable(res, alloc, full, v);
        } else if (parseValue(v)) |val| {
            try res.set(alloc, full, val);
        } else {
            res.skipped += 1;
        }
    }
}

/// 解析数组：`[ {..}, {..} ]` 或 `["a", "b"]`，元素记为 `prefix[i]`。
fn parseArray(res: *ParseResult, alloc: std.mem.Allocator, prefix: []const u8, body_in: []const u8) !void {
    var body = body_in;
    if (body.len >= 2 and body[0] == '[' and body[body.len - 1] == ']') body = body[1 .. body.len - 1];
    var idx: usize = 0;
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    var items: [32][]const u8 = undefined;
    var n_items: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        const c: u8 = if (at_end) ',' else body[i];
        switch (c) {
            '{', '[' => depth += 1,
            '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            '"' => {},
            else => {},
        }
        if (c == ',' and depth == 0) {
            if (n_items < items.len) {
                items[n_items] = std.mem.trim(u8, body[start..i], " \t");
                n_items += 1;
            }
            start = i + 1;
        }
    }
    for (items[0..n_items]) |item| {
        if (item.len == 0) continue;
        const key = try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ prefix, idx });
        idx += 1;
        if (item[0] == '{') {
            try parseInlineTable(res, alloc, key, item);
        } else if (parseValue(item)) |v| {
            try res.set(alloc, key, v);
        } else {
            res.skipped += 1;
        }
    }
}

/// 统计方括号/花括号的净值（字符串内的不计）。
fn bracketDelta(text: []const u8) isize {
    var d: isize = 0;
    var in_str = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"' and (i == 0 or text[i - 1] != '\\')) in_str = !in_str;
        if (in_str) continue;
        switch (c) {
            '[', '{' => d += 1,
            ']', '}' => d -= 1,
            else => {},
        }
    }
    return d;
}

/// 解析整份配置文本；分配出的 key 由调用方的 arena/allocator 持有。
/// 支持跨行的数组（`bindings = [\n {...},\n {...},\n]`）。
pub fn parse(alloc: std.mem.Allocator, text: []const u8) !ParseResult {
    var res: ParseResult = .{};
    errdefer res.deinit(alloc);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it0 = std.mem.splitScalar(u8, text, '\n');
    while (it0.next()) |l| try lines.append(alloc, l);

    var section: []const u8 = "";
    // [[name]] 的计数：用于把元素展开成 name[i].field
    var array_counts: [16]struct { name: []const u8, count: usize } = undefined;
    var n_array_names: usize = 0;
    var li: usize = 0;
    while (li < lines.items.len) : (li += 1) {
        const line = std.mem.trim(u8, trimComment(lines.items[li]), " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (line.len >= 4 and line[1] == '[' and line[line.len - 1] == ']' and line[line.len - 2] == ']') {
                const name = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
                var idx: usize = 0;
                var found = false;
                var i: usize = 0;
                while (i < n_array_names) : (i += 1) {
                    if (std.mem.eql(u8, array_counts[i].name, name)) {
                        array_counts[i].count += 1;
                        idx = array_counts[i].count - 1;
                        found = true;
                        break;
                    }
                }
                if (!found and n_array_names < array_counts.len) {
                    array_counts[n_array_names] = .{ .name = name, .count = 1 };
                    n_array_names += 1;
                    idx = 0;
                }
                section = try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ name, idx });
                continue;
            }
            if (line[line.len - 1] != ']') {
                res.skipped += 1;
                continue;
            }
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            res.skipped += 1;
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var value_text = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) {
            res.skipped += 1;
            continue;
        }

        // 跨行数组：把后续行拼进来直到括号配平
        if (value_text.len > 0 and (value_text[0] == '[' or value_text[0] == '{')) {
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(alloc);
            try joined.appendSlice(alloc, value_text);
            var depth = bracketDelta(value_text);
            while (depth > 0 and li + 1 < lines.items.len) {
                li += 1;
                const next = std.mem.trim(u8, trimComment(lines.items[li]), " \t\r");
                try joined.append(alloc, ' ');
                try joined.appendSlice(alloc, next);
                depth += bracketDelta(next);
            }
            // 必须复制：joined 在本块结束时就被 deinit，value_text 不能指向它
            value_text = try alloc.dupe(u8, joined.items);
        }

        const full = if (section.len == 0)
            try alloc.dupe(u8, key)
        else
            try std.fmt.allocPrint(alloc, "{s}.{s}", .{ section, key });

        if (value_text.len > 0 and value_text[0] == '[') {
            try parseArray(&res, alloc, full, value_text);
        } else if (value_text.len > 0 and value_text[0] == '{') {
            try parseInlineTable(&res, alloc, full, value_text);
        } else if (parseValue(value_text)) |v| {
            try res.set(alloc, full, v);
        } else {
            res.skipped += 1;
        }
    }
    return res;
}
