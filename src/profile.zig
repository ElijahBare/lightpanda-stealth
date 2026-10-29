// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

//! A persistent browser profile (`--profile-dir`), the counterpart of
//! Chrome's `--user-data-dir`: the default session's persistent cookies and
//! localStorage are loaded from the directory when it starts and written back
//! when it closes. Session cookies and sessionStorage end with the session,
//! as in Chrome, so they are never written.
//!
//! Each kind of data is a versioned JSON file, replaced atomically on save.
//! A file that is missing, unreadable, corrupt or of an unknown version is
//! logged and ignored: the session then starts without that data.

const std = @import("std");
const lp = @import("lightpanda");

const cookies = @import("cookies.zig");
const Session = @import("browser/Session.zig");
const storage = @import("browser/webapi/storage/storage.zig");

const log = lp.log;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const Cookie = storage.Cookie;

pub const format_version = 1;
pub const cookies_file = "cookies.json";
pub const local_storage_file = "local_storage.json";

const max_cookies_size = 16 * 1024 * 1024;
const max_local_storage_size = 256 * 1024 * 1024;

/// Loads the profile at `dir_path` into a fresh session, creating the
/// directory if it's missing.
pub fn load(session: *Session, dir_path: []const u8) void {
    var dir = openDir(dir_path) orelse return;
    defer dir.close(lp.io);

    const cookie_count = loadCookies(dir, &session.cookie_jar);
    const origin_count = loadLocalStorage(dir, &session.storage_shed, session.browser.app.allocator);
    log.info(.app, "Profile.load", .{ .path = dir_path, .cookies = cookie_count, .origins = origin_count });
}

/// Writes the session's persistent cookies and localStorage to the profile
/// at `dir_path`.
pub fn save(session: *Session, dir_path: []const u8) void {
    var dir = openDir(dir_path) orelse return;
    defer dir.close(lp.io);

    saveCookies(dir, &session.cookie_jar);
    saveLocalStorage(dir, &session.storage_shed);
    log.info(.app, "Profile.save", .{ .path = dir_path });
}

fn openDir(dir_path: []const u8) ?Dir {
    return Dir.cwd().createDirPathOpen(lp.io, dir_path, .{}) catch |err| {
        log.err(.app, "Profile.openDir", .{ .path = dir_path, .err = err });
        return null;
    };
}

/// The file's content, or null (logged) when it can't be read. A missing
/// file is the normal state of a new profile.
fn readFile(dir: Dir, allocator: Allocator, name: []const u8, limit: usize) ?[]const u8 {
    return dir.readFileAlloc(lp.io, name, allocator, .limited(limit)) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => log.err(.app, "Profile.readFile", .{ .file = name, .err = err }),
        }
        return null;
    };
}

/// Rejects a file written by a newer, incompatible version.
fn checkVersion(allocator: Allocator, name: []const u8, content: []const u8) bool {
    const header = std.json.parseFromSliceLeaky(struct { version: u32 }, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.err(.app, "Profile.parseFile", .{ .file = name, .err = err });
        return false;
    };
    if (header.version != format_version) {
        log.err(.app, "Profile.parseFile", .{ .file = name, .version = header.version, .note = "unsupported version" });
        return false;
    }
    return true;
}

// cookies.json: {"version":1,"cookies":[<CDP Network.Cookie>, ...]}
fn loadCookies(dir: Dir, jar: *Cookie.Jar) usize {
    var arena = std.heap.ArenaAllocator.init(jar.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const content = readFile(dir, allocator, cookies_file, max_cookies_size) orelse return 0;
    if (!checkVersion(allocator, cookies_file, content)) {
        return 0;
    }

    const parsed = std.json.parseFromSliceLeaky(struct {
        cookies: []const cookies.JsonCookie,
    }, allocator, content, .{ .ignore_unknown_fields = true }) catch |err| {
        log.err(.app, "Profile.parseFile", .{ .file = cookies_file, .err = err });
        return 0;
    };

    return cookies.addJsonCookies(jar, parsed.cookies) catch |err| {
        log.err(.app, "Profile.loadCookies", .{ .err = err });
        return 0;
    };
}

fn saveCookies(dir: Dir, jar: *Cookie.Jar) void {
    _saveCookies(dir, jar) catch |err| {
        log.err(.app, "Profile.saveCookies", .{ .err = err });
    };
}

fn _saveCookies(dir: Dir, jar: *Cookie.Jar) !void {
    jar.removeExpired(null);

    var af = try dir.createFileAtomic(lp.io, cookies_file, .{ .replace = true });
    defer af.deinit(lp.io);

    var buf: [8192]u8 = undefined;
    var writer = af.file.writer(lp.io, &buf);
    const w = &writer.interface;
    try w.print("{{\"version\":{d},\"cookies\":", .{format_version});
    try cookies.writeJson(jar, w, .{ .persistent_only = true });
    try w.writeAll("}\n");
    try writer.end();
    try af.replace(lp.io);
}

// local_storage.json: {"version":1,"origins":{"https://example.com":{"key":"value"}}}
fn loadLocalStorage(dir: Dir, shed: *storage.Shed, shed_allocator: Allocator) usize {
    var arena = std.heap.ArenaAllocator.init(shed_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const content = readFile(dir, allocator, local_storage_file, max_local_storage_size) orelse return 0;
    if (!checkVersion(allocator, local_storage_file, content)) {
        return 0;
    }

    const Items = std.json.ArrayHashMap([]const u8);
    const parsed = std.json.parseFromSliceLeaky(struct {
        origins: std.json.ArrayHashMap(Items),
    }, allocator, content, .{ .ignore_unknown_fields = true }) catch |err| {
        log.err(.app, "Profile.parseFile", .{ .file = local_storage_file, .err = err });
        return 0;
    };

    var loaded: usize = 0;
    var it = parsed.origins.map.iterator();
    while (it.next()) |origin| {
        if (!isPersistableOrigin(origin.key_ptr.*)) {
            continue;
        }
        const bucket = shed.getOrPut(shed_allocator, origin.key_ptr.*) catch |err| {
            log.err(.app, "Profile.loadLocalStorage", .{ .err = err });
            return loaded;
        };
        var items = origin.value_ptr.map.iterator();
        while (items.next()) |item| {
            bucket.local.setItem(item.key_ptr.*, item.value_ptr.*) catch |err| {
                log.warn(.app, "Profile.loadLocalStorage", .{ .origin = origin.key_ptr.*, .err = err });
                break;
            };
        }
        loaded += 1;
    }
    return loaded;
}

fn saveLocalStorage(dir: Dir, shed: *const storage.Shed) void {
    _saveLocalStorage(dir, shed) catch |err| {
        log.err(.app, "Profile.saveLocalStorage", .{ .err = err });
    };
}

fn _saveLocalStorage(dir: Dir, shed: *const storage.Shed) !void {
    var af = try dir.createFileAtomic(lp.io, local_storage_file, .{ .replace = true });
    defer af.deinit(lp.io);

    var buf: [8192]u8 = undefined;
    var writer = af.file.writer(lp.io, &buf);
    var s: std.json.Stringify = .{ .writer = &writer.interface };

    try s.beginObject();
    try s.objectField("version");
    try s.write(format_version);
    try s.objectField("origins");
    try s.beginObject();
    var it = shed._origins.iterator();
    while (it.next()) |origin| {
        const local = &origin.value_ptr.*.local;
        if (local.getLength() == 0 or !isPersistableOrigin(origin.key_ptr.*)) {
            continue;
        }
        try s.objectField(origin.key_ptr.*);
        try s.beginObject();
        var items = local._data.iterator();
        while (items.next()) |item| {
            try s.objectField(item.key_ptr.*);
            try s.write(item.value_ptr.*);
        }
        try s.endObject();
    }
    try s.endObject();
    try s.endObject();
    try writer.interface.writeByte('\n');

    try writer.end();
    try af.replace(lp.io);
}

/// Opaque origins (about:blank, data:, ...) are keyed by a fresh uuid and
/// a document.domain one by a '!'-marked key: neither can be visited again.
fn isPersistableOrigin(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "http://") or std.mem.startsWith(u8, key, "https://");
}

const testing = std.testing;

fn findCookie(jar: *const Cookie.Jar, name: []const u8) ?*Cookie {
    var it = jar.iterator();
    while (it.next()) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

test "profile: cookies round-trip, session and expired cookies dropped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var jar = Cookie.Jar.init(testing.allocator, null);
        defer jar.deinit();
        try jar.populateFromResponse("https://example.com/", "persistent=1; Path=/; Max-Age=3600; HttpOnly; Secure; SameSite=Strict");
        try jar.populateFromResponse("https://example.com/", "session=2; Path=/");
        try jar.populateFromResponse("https://other.test/a", "far=3; Expires=Fri, 01 Jan 2100 00:00:00 GMT");
        try testing.expectEqual(3, jar.len);
        saveCookies(tmp.dir, &jar);
    }

    // A cookie that expired since the last save is dropped on load.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const content = try tmp.dir.readFileAlloc(lp.io, cookies_file, arena.allocator(), .unlimited);
        try testing.expect(std.mem.find(u8, content, "\"session\"") == null);
        try testing.expect(std.mem.startsWith(u8, content, "{\"version\":1,"));

        const stale = try std.mem.concat(arena.allocator(), u8, &.{
            content[0..std.mem.findScalarLast(u8, content, ']').?],
            ",{\"name\":\"stale\",\"value\":\"4\",\"domain\":\"example.com\",\"path\":\"/\",\"expires\":1000}]}\n",
        });
        try tmp.dir.writeFile(lp.io, .{ .sub_path = cookies_file, .data = stale });
    }

    var jar = Cookie.Jar.init(testing.allocator, null);
    defer jar.deinit();
    // Jar.add takes the stale cookie as a deletion, so it isn't rejected,
    // just not stored.
    _ = loadCookies(tmp.dir, &jar);
    try testing.expectEqual(2, jar.len);
    try testing.expect(findCookie(&jar, "session") == null);
    try testing.expect(findCookie(&jar, "stale") == null);

    const persistent = findCookie(&jar, "persistent").?;
    try testing.expectEqualStrings("1", persistent.value);
    try testing.expectEqualStrings("example.com", persistent.domain);
    try testing.expect(persistent.http_only);
    try testing.expect(persistent.secure);
    try testing.expectEqual(Cookie.SameSite.strict, persistent.same_site);
    try testing.expect(persistent.expires != null);

    const far = findCookie(&jar, "far").?;
    try testing.expectEqualStrings("3", far.value);
    try testing.expectEqual(@as(?f64, 4102444800), far.expires);
}

test "profile: localStorage round-trips per origin, sessionStorage dropped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var shed: storage.Shed = .{};
        defer shed.deinit(testing.allocator);

        const a = try shed.getOrPut(testing.allocator, "https://example.com");
        try a.local.setItem("token", "abc");
        try a.local.setItem("quote", "say \"hi\"\n\u{e9}");
        try a.session.setItem("tab", "1");

        const b = try shed.getOrPut(testing.allocator, "http://other.test:8080");
        try b.local.setItem("token", "xyz");

        // Only sessionStorage, and an opaque origin: neither is written.
        const c = try shed.getOrPut(testing.allocator, "https://session-only.test");
        try c.session.setItem("k", "v");
        const d = try shed.getOrPut(testing.allocator, "3f2504e0-4f89-41d3-9a0c-0305e82c3301");
        try d.local.setItem("k", "v");

        saveLocalStorage(tmp.dir, &shed);
    }

    var shed: storage.Shed = .{};
    defer shed.deinit(testing.allocator);
    try testing.expectEqual(2, loadLocalStorage(tmp.dir, &shed, testing.allocator));
    try testing.expectEqual(2, shed._origins.count());

    const a = shed._origins.get("https://example.com").?;
    try testing.expectEqual(2, a.local.getLength());
    try testing.expectEqualStrings("abc", a.local.getItem("token").?);
    try testing.expectEqualStrings("say \"hi\"\n\u{e9}", a.local.getItem("quote").?);
    try testing.expectEqual(0, a.session.getLength());

    const b = shed._origins.get("http://other.test:8080").?;
    try testing.expectEqualStrings("xyz", b.local.getItem("token").?);
}

test "profile: corrupt or unknown-version files are ignored" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var jar = Cookie.Jar.init(testing.allocator, null);
    defer jar.deinit();
    var shed: storage.Shed = .{};
    defer shed.deinit(testing.allocator);

    // No files at all: a brand new profile.
    try testing.expectEqual(0, loadCookies(tmp.dir, &jar));
    try testing.expectEqual(0, loadLocalStorage(tmp.dir, &shed, testing.allocator));

    try tmp.dir.writeFile(lp.io, .{ .sub_path = cookies_file, .data = "{\"version\":1,\"cookies\":[{\"name\":" });
    try tmp.dir.writeFile(lp.io, .{ .sub_path = local_storage_file, .data = "\x00garbage" });
    try testing.expectEqual(0, loadCookies(tmp.dir, &jar));
    try testing.expectEqual(0, loadLocalStorage(tmp.dir, &shed, testing.allocator));

    // Well-formed, but a shape or version this build doesn't know.
    try tmp.dir.writeFile(lp.io, .{ .sub_path = cookies_file, .data = "{\"version\":99,\"cookies\":[]}" });
    try tmp.dir.writeFile(lp.io, .{ .sub_path = local_storage_file, .data = "{\"version\":1,\"origins\":[1,2]}" });
    try testing.expectEqual(0, loadCookies(tmp.dir, &jar));
    try testing.expectEqual(0, loadLocalStorage(tmp.dir, &shed, testing.allocator));

    try testing.expectEqual(0, jar.len);
    try testing.expectEqual(0, shed._origins.count());

    // And the next save replaces them.
    try jar.populateFromResponse("https://example.com/", "sid=1; Max-Age=3600");
    saveCookies(tmp.dir, &jar);
    var reloaded = Cookie.Jar.init(testing.allocator, null);
    defer reloaded.deinit();
    try testing.expectEqual(1, loadCookies(tmp.dir, &reloaded));
}

test "profile: load creates a missing directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try @import("testing.zig").tmpPath(&tmp, "nested/profile");
    var dir = openDir(path).?;
    dir.close(lp.io);

    var check = try tmp.dir.openDir(lp.io, "nested/profile", .{});
    check.close(lp.io);
}
