// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");

const CDP = @import("../CDP.zig");
const storage = @import("../../../browser/webapi/storage/storage.zig");

const log = lp.log;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        getDOMStorageItems,
        setDOMStorageItem,
        removeDOMStorageItem,
        clear,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable, .disable => return cmd.sendResult(null, .{}),
        .getDOMStorageItems => return getDOMStorageItems(cmd),
        .setDOMStorageItem => return setDOMStorageItem(cmd),
        .removeDOMStorageItem => return removeDOMStorageItem(cmd),
        .clear => return clear(cmd),
    }
}

const StorageId = struct {
    securityOrigin: ?[]const u8 = null,
    storageKey: ?[]const u8 = null,
    isLocalStorage: bool,
};

fn getDOMStorageItems(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct { storageId: StorageId })) orelse return error.InvalidParams;
    const lookup = findStorageArea(cmd, params.storageId) orelse return sendNotFound(cmd);
    return cmd.sendResult(.{ .entries = EntriesWriter{ .lookup = lookup } }, .{});
}

fn setDOMStorageItem(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        storageId: StorageId,
        key: []const u8,
        value: []const u8,
    })) orelse return error.InvalidParams;
    const lookup = findStorageArea(cmd, params.storageId) orelse return sendNotFound(cmd);
    lookup.setItem(params.key, params.value) catch |err| switch (err) {
        error.QuotaExceeded => return cmd.sendError(-32000, "QuotaExceededError", .{}),
        else => return err,
    };
    return cmd.sendResult(null, .{});
}

fn removeDOMStorageItem(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        storageId: StorageId,
        key: []const u8,
    })) orelse return error.InvalidParams;
    const lookup = findStorageArea(cmd, params.storageId) orelse return sendNotFound(cmd);
    lookup.removeItem(params.key);
    return cmd.sendResult(null, .{});
}

fn clear(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct { storageId: StorageId })) orelse return error.InvalidParams;
    const lookup = findStorageArea(cmd, params.storageId) orelse return sendNotFound(cmd);
    lookup.clear();
    return cmd.sendResult(null, .{});
}

fn sendNotFound(cmd: *CDP.Command) !void {
    // Chrome's InspectorDOMStorageAgent::FindStorageArea.
    return cmd.sendError(-32000, "Frame not found for the given storage id", .{});
}

// The storage area of the main frame, when its origin is the one the
// storage id names. Chrome looks the origin up among all the frames; we only
// have the main one to offer.
fn findStorageArea(cmd: *CDP.Command, storage_id: StorageId) ?*storage.Lookup {
    const bc = cmd.browser_context orelse return null;
    const frame = bc.mainFrame() orelse return null;
    // An opaque origin (about:blank, data:, file:) has no storage CDP can name.
    const origin = frame.origin orelse return null;

    if (storage_id.securityOrigin) |security_origin| {
        if (!std.mem.eql(u8, security_origin, origin)) return null;
    }
    if (storage_id.storageKey) |storage_key| {
        // A first-party storage key is the origin with a trailing slash.
        const key_origin = if (std.mem.endsWith(u8, storage_key, "/")) storage_key[0 .. storage_key.len - 1] else storage_key;
        if (!std.mem.eql(u8, key_origin, origin)) return null;
    }

    // The same bucket Window.localStorage and Window.sessionStorage use.
    const session = bc.session;
    const bucket = session.storage_shed.getOrPut(session.browser.app.allocator, frame.js.origin.key) catch |err| {
        log.err(.cdp, "storage bucket", .{ .err = err });
        return null;
    };
    return if (storage_id.isLocalStorage) &bucket.local else &bucket.session;
}

// DOMStorage.Item is a [key, value] array.
const EntriesWriter = struct {
    lookup: *const storage.Lookup,

    pub fn jsonStringify(self: *const EntriesWriter, w: anytype) !void {
        try w.beginArray();
        var it = self.lookup.iterator();
        while (it.next()) |entry| {
            try w.beginArray();
            try w.write(entry.key_ptr.*);
            try w.write(entry.value_ptr.*);
            try w.endArray();
        }
        try w.endArray();
    }
};

const testing = @import("../testing.zig");
const js = @import("../../../browser/js/js.zig");

const origin_under_test = "http://127.0.0.1:9582";

fn expectJs(frame: *lp.Frame, expression: [:0]const u8) !void {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const value = try ls.local.exec(expression, null);
    try testing.expect(value.toBool());
}

fn execJs(frame: *lp.Frame, expression: [:0]const u8) !void {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec(expression, null);
}

test "cdp.DOMStorage: enable and disable" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-DS0" });

    try ctx.processMessage(.{ .id = 1, .method = "DOMStorage.enable" });
    try ctx.expectSentResult(null, .{ .id = 1 });
    try ctx.processMessage(.{ .id = 2, .method = "DOMStorage.disable" });
    try ctx.expectSentResult(null, .{ .id = 2 });
}

test "cdp.DOMStorage: set via CDP, read via JS" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-DS1", .url = "hi.html" });
    const frame = bc.mainFrame().?;

    const local_id: StorageId = .{ .securityOrigin = origin_under_test, .isLocalStorage = true };
    try ctx.processMessage(.{ .id = 1, .method = "DOMStorage.setDOMStorageItem", .params = .{ .storageId = local_id, .key = "k1", .value = "v1" } });
    try ctx.expectSentResult(null, .{ .id = 1 });
    try ctx.processMessage(.{ .id = 2, .method = "DOMStorage.setDOMStorageItem", .params = .{ .storageId = local_id, .key = "k2", .value = "v2" } });
    try ctx.expectSentResult(null, .{ .id = 2 });

    // storageKey works as securityOrigin does.
    const session_id: StorageId = .{ .storageKey = origin_under_test ++ "/", .isLocalStorage = false };
    try ctx.processMessage(.{ .id = 3, .method = "DOMStorage.setDOMStorageItem", .params = .{ .storageId = session_id, .key = "s", .value = "sv" } });
    try ctx.expectSentResult(null, .{ .id = 3 });

    try expectJs(frame, "localStorage.getItem('k1') === 'v1' && localStorage.getItem('k2') === 'v2' && localStorage.length === 2");
    try expectJs(frame, "sessionStorage.getItem('s') === 'sv' && sessionStorage.length === 1");

    try ctx.processMessage(.{ .id = 4, .method = "DOMStorage.removeDOMStorageItem", .params = .{ .storageId = local_id, .key = "k1" } });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try expectJs(frame, "localStorage.getItem('k1') === null && localStorage.getItem('k2') === 'v2'");

    try ctx.processMessage(.{ .id = 5, .method = "DOMStorage.clear", .params = .{ .storageId = local_id } });
    try ctx.expectSentResult(null, .{ .id = 5 });
    try expectJs(frame, "localStorage.length === 0 && sessionStorage.length === 1");

    // Another origin isn't the main frame's.
    try ctx.processMessage(.{ .id = 6, .method = "DOMStorage.setDOMStorageItem", .params = .{ .storageId = StorageId{ .securityOrigin = "https://example.com", .isLocalStorage = true }, .key = "x", .value = "y" } });
    try ctx.expectSentError(-32000, "Frame not found for the given storage id", .{ .id = 6 });
}

test "cdp.DOMStorage: set via JS, read via CDP" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const bc = try ctx.loadBrowserContext(.{ .id = "BID-DS2", .url = "hi.html" });
    const frame = bc.mainFrame().?;

    try execJs(frame, "localStorage.clear(); localStorage.setItem('a', '1'); sessionStorage.setItem('b', '2')");

    try ctx.processMessage(.{ .id = 1, .method = "DOMStorage.getDOMStorageItems", .params = .{ .storageId = StorageId{ .securityOrigin = origin_under_test, .isLocalStorage = true } } });
    try ctx.expectSentResult(.{ .entries = &[_][2][]const u8{.{ "a", "1" }} }, .{ .id = 1 });

    try ctx.processMessage(.{ .id = 2, .method = "DOMStorage.getDOMStorageItems", .params = .{ .storageId = StorageId{ .isLocalStorage = false } } });
    try ctx.expectSentResult(.{ .entries = &[_][2][]const u8{.{ "b", "2" }} }, .{ .id = 2 });
}

test "cdp.DOMStorage: no page" {
    var ctx = try testing.context();
    defer ctx.deinit();
    _ = try ctx.loadBrowserContext(.{ .id = "BID-DS3" });

    try ctx.processMessage(.{ .id = 1, .method = "DOMStorage.getDOMStorageItems", .params = .{ .storageId = StorageId{ .isLocalStorage = true } } });
    try ctx.expectSentError(-32000, "Frame not found for the given storage id", .{ .id = 1 });
}
