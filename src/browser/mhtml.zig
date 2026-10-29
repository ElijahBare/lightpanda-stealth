// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

// MHTML (multipart/related, RFC 2557) snapshot of a frame tree, behind
// `Page.captureSnapshot`. Laid out like Chrome's: a message header, then one
// quoted-printable text/html part per frame, the main frame first. Each part
// is the frame's serialized DOM, as DOM.getOuterHTML would give it.
// Subresources (images, stylesheets) aren't included.

const std = @import("std");
const lp = @import("lightpanda");

const dump = @import("dump.zig");
const Frame = @import("Frame.zig");

const Allocator = std.mem.Allocator;

pub fn write(allocator: Allocator, frame: *Frame, writer: *std.Io.Writer) !void {
    var boundary_buf: [boundary_prefix.len + 32 + 4]u8 = undefined;
    const boundary = makeBoundary(&boundary_buf);

    try writer.writeAll("From: <Saved by Lightpanda>\r\n");
    try writer.writeAll("Snapshot-Content-Location: ");
    try writeHeaderValue(frame.url, writer);
    try writer.writeAll("\r\nSubject: ");
    try writeSubject((try frame.getTitle()) orelse "", writer);
    try writer.writeAll("\r\nDate: ");
    try writeDate(lp.datetime.DateTime.now(), writer);
    try writer.print(
        "\r\nMIME-Version: 1.0\r\n" ++
            "Content-Type: multipart/related;\r\n" ++
            "\ttype=\"text/html\";\r\n" ++
            "\tboundary=\"{s}\"\r\n\r\n\r\n",
        .{boundary},
    );

    var html: std.Io.Writer.Allocating = .init(allocator);
    defer html.deinit();
    try writeFrame(frame, boundary, &html, writer);

    try writer.print("--{s}--\r\n", .{boundary});
}

fn writeFrame(frame: *Frame, boundary: []const u8, html: *std.Io.Writer.Allocating, writer: *std.Io.Writer) !void {
    html.clearRetainingCapacity();
    try dump.root(frame.window._document, .{}, &html.writer, frame);

    try writer.print(
        "--{s}\r\n" ++
            "Content-Type: text/html; charset=utf-8\r\n" ++
            "Content-ID: <frame-{d}@mhtml.lightpanda>\r\n" ++
            "Content-Transfer-Encoding: quoted-printable\r\n" ++
            "Content-Location: ",
        .{ boundary, frame._frame_id },
    );
    try writeHeaderValue(frame.url, writer);
    try writer.writeAll("\r\n\r\n");
    try writeQuotedPrintable(html.written(), writer);
    try writer.writeAll("\r\n\r\n");

    for (frame.child_frames.items) |child| {
        try writeFrame(child, boundary, html, writer);
    }
}

const boundary_prefix = "----MultipartBoundary--";

fn makeBoundary(buf: []u8) []const u8 {
    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    var rand: [32]u8 = undefined;
    lp.io.random(&rand);

    @memcpy(buf[0..boundary_prefix.len], boundary_prefix);
    for (rand, buf[boundary_prefix.len..][0..32]) |r, *c| {
        c.* = alphabet[r % alphabet.len];
    }
    @memcpy(buf[boundary_prefix.len + 32 ..][0..4], "----");
    return buf[0 .. boundary_prefix.len + 36];
}

// A header value never breaks the header block: CR, LF and other control
// characters are dropped.
fn writeHeaderValue(value: []const u8, writer: *std.Io.Writer) !void {
    for (value) |c| {
        if (c < 0x20 or c == 0x7f) continue;
        try writer.writeByte(c);
    }
}

// RFC 2047 encoded-words for a non-ASCII title, each kept under the 75
// character limit and split only between UTF-8 sequences.
fn writeSubject(title: []const u8, writer: *std.Io.Writer) !void {
    const needs_encoding = for (title) |c| {
        if (c < 0x20 or c >= 0x7f) break true;
    } else false;
    if (!needs_encoding) return writer.writeAll(title);

    const hex = "0123456789ABCDEF";
    // "=?utf-8?Q?" + "?=" leaves 63; keep room for a 4-byte sequence (12).
    const max_word = 50;
    var word_len: usize = 0;
    try writer.writeAll("=?utf-8?Q?");
    for (title) |c| {
        const continuation = c & 0xc0 == 0x80;
        if (!continuation and word_len >= max_word) {
            try writer.writeAll("?=\r\n =?utf-8?Q?");
            word_len = 0;
        }
        if (c == ' ') {
            try writer.writeByte('_');
            word_len += 1;
        } else if (std.ascii.isAlphanumeric(c)) {
            try writer.writeByte(c);
            word_len += 1;
        } else {
            try writer.writeAll(&.{ '=', hex[c >> 4], hex[c & 0xf] });
            word_len += 3;
        }
    }
    try writer.writeAll("?=");
}

// RFC 822 date, as Chrome writes it: "Wed, 29 Oct 2026 12:00:00 -0000".
fn writeDate(dt: lp.datetime.DateTime, writer: *std.Io.Writer) !void {
    const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const date = dt.date();
    const time = dt.time();
    // 1970-01-01 was a Thursday.
    const epoch_day = @divFloor(dt.micros, std.time.us_per_day);
    const weekday: usize = @intCast(@mod(epoch_day + 4, 7));
    try writer.print("{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} -0000", .{
        days[weekday],
        date.day,
        months[date.month - 1],
        date.year,
        time.hour,
        time.min,
        time.sec,
    });
}

// RFC 2045 quoted-printable. Line breaks become CRLF hard breaks, lines are
// soft-broken to stay within 76 characters, and whitespace before a break is
// encoded so it survives transport.
fn writeQuotedPrintable(input: []const u8, writer: *std.Io.Writer) !void {
    const hex = "0123456789ABCDEF";
    const max_line = 75; // plus the soft break's "="

    var col: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '\n' or (c == '\r' and i + 1 < input.len and input[i + 1] == '\n')) {
            if (c == '\r') i += 1;
            try writer.writeAll("\r\n");
            col = 0;
            continue;
        }

        const literal = switch (c) {
            '!'...'<', '>'...'~' => true,
            ' ', '\t' => blk: {
                if (i + 1 == input.len) break :blk false;
                const next = input[i + 1];
                break :blk next != '\n' and next != '\r';
            },
            else => false,
        };

        const width: usize = if (literal) 1 else 3;
        if (col + width > max_line) {
            try writer.writeAll("=\r\n");
            col = 0;
        }
        if (literal) {
            try writer.writeByte(c);
        } else {
            try writer.writeAll(&.{ '=', hex[c >> 4], hex[c & 0xf] });
        }
        col += width;
    }
}

const testing = @import("../testing.zig");
const repeat = @import("../string.zig").repeat;

fn expectQP(expected: []const u8, input: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeQuotedPrintable(input, &aw.writer);
    try testing.expectEqual(expected, aw.written());
}

test "mhtml: quoted-printable" {
    try expectQP("<p class=3D\"a\">caf=C3=A9</p>", "<p class=\"a\">café</p>");
    try expectQP("a\r\nb\r\nc", "a\nb\r\nc");
    try expectQP("trailing=20\r\ntab=09", "trailing \ntab\t");
    try expectQP("lone=0Dcr", "lone\rcr");

    const long = repeat("x", 80);
    try expectQP(repeat("x", 75) ++ "=\r\n" ++ repeat("x", 5), long);

    // An escape is never split across a soft break.
    try expectQP(repeat("x", 74) ++ "=\r\n=3Dy", repeat("x", 74) ++ "=y");
}

fn expectSubject(expected: []const u8, input: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeSubject(input, &aw.writer);
    try testing.expectEqual(expected, aw.written());
}

test "mhtml: subject" {
    try expectSubject("Plain title", "Plain title");
    try expectSubject("=?utf-8?Q?Caf=C3=A9_menu?=", "Café menu");
    try expectSubject("=?utf-8?Q?" ++ repeat("a", 50) ++ "?=\r\n =?utf-8?Q?=C3=A9?=", repeat("a", 50) ++ "é");
}

test "mhtml: date" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeDate(try .initUTC(2026, 10, 29, 9, 5, 7, 0), &aw.writer);
    try testing.expectEqual("Thu, 29 Oct 2026 09:05:07 -0000", aw.written());
}
