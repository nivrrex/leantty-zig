//! 配置键绑定的公共解析与动作映射；平台层只负责把按键映射成键名。

pub const Action = enum {
    copy,
    paste,
    scroll_page_up,
    scroll_page_down,
    scroll_top,
    scroll_bottom,
    quit,
};

pub const Spec = struct {
    ctrl: bool,
    shift: bool,
    alt: bool,
    key: []const u8,
};

/// 解析 "Ctrl+Shift+C" 这类描述；未知修饰键或空键名返回 null。
pub fn parse(text: []const u8) ?Spec {
    var ctrl = false;
    var shift = false;
    var alt = false;
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        const mod = std.mem.trim(u8, rest[0..plus], " ");
        if (std.mem.eql(u8, mod, "Ctrl") or std.mem.eql(u8, mod, "Control")) {
            ctrl = true;
        } else if (std.mem.eql(u8, mod, "Shift")) {
            shift = true;
        } else if (std.mem.eql(u8, mod, "Alt")) {
            alt = true;
        } else {
            return null;
        }
        rest = rest[plus + 1 ..];
    }
    const key = std.mem.trim(u8, rest, " ");
    if (key.len == 0) return null;
    return .{ .ctrl = ctrl, .shift = shift, .alt = alt, .key = key };
}

pub fn actionFromName(name: []const u8) ?Action {
    const map = .{
        .{ "Copy", Action.copy },
        .{ "Paste", Action.paste },
        .{ "ScrollPageUp", Action.scroll_page_up },
        .{ "ScrollPageDown", Action.scroll_page_down },
        .{ "ScrollToTop", Action.scroll_top },
        .{ "ScrollToBottom", Action.scroll_bottom },
        .{ "Quit", Action.quit },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

const std = @import("std");
const testing = std.testing;

test "parse：组合键与独立 mods 写法" {
    const a = parse("Ctrl+Shift+C").?;
    try testing.expect(a.ctrl and a.shift and !a.alt);
    try testing.expectEqualStrings("C", a.key);
    const b = parse("Control+Insert").?;
    try testing.expect(b.ctrl);
    try testing.expectEqualStrings("Insert", b.key);
    try testing.expect(parse("Hyper+C") == null);
    try testing.expect(parse("") == null);
}

test "actionFromName：已知动作与未知动作" {
    try testing.expectEqual(Action.copy, actionFromName("Copy").?);
    try testing.expectEqual(Action.quit, actionFromName("Quit").?);
    try testing.expect(actionFromName("Unknown") == null);
}
