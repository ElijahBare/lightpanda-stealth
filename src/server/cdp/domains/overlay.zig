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

const std = @import("std");
const lp = @import("lightpanda");

const CDP = @import("../CDP.zig");
const dom = @import("dom.zig");
const NodeRegistry = @import("../../../NodeRegistry.zig");

const log = lp.log;

// Lightpanda doesn't render, so the overlay is never drawn. Methods validate
// their params like Chrome does and succeed without any visual effect.
pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        highlightNode,
        hideHighlight,
        highlightRect,
        setInspectMode,
        setShowViewportSizeOnResize,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .disable => return cmd.sendResult(null, .{}),
        .highlightNode => return highlightNode(cmd),
        .hideHighlight => return cmd.sendResult(null, .{}),
        .highlightRect => return highlightRect(cmd),
        .setInspectMode => return setInspectMode(cmd),
        .setShowViewportSizeOnResize => return setShowViewportSizeOnResize(cmd),
    }
}

// https://chromedevtools.github.io/devtools-protocol/tot/Overlay/#method-highlightNode
fn highlightNode(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        highlightConfig: std.json.Value,
        nodeId: ?NodeRegistry.Id = null,
        backendNodeId: ?NodeRegistry.Id = null,
        objectId: ?[]const u8 = null,
        selector: ?[]const u8 = null,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    _ = dom.getNode(cmd.arena, bc, cmd.input.session_id, params.nodeId, params.backendNodeId, params.objectId) catch |err| switch (err) {
        error.MissingParams => return cmd.sendError(-32000, "Either nodeId, backendNodeId or objectId must be specified", .{}),
        error.NodeNotFound => return cmd.sendError(-32000, "Could not find node with given id", .{}),
        else => return err,
    };

    if (params.selector != null) {
        log.debug(.not_implemented, "Overlay.highlightNode", .{ .param = "selector" });
    }
    return cmd.sendResult(null, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/Overlay/#method-highlightRect
fn highlightRect(cmd: *CDP.Command) !void {
    _ = (try cmd.params(struct {
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    })) orelse return error.InvalidParams;
    return cmd.sendResult(null, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/Overlay/#method-setInspectMode
fn setInspectMode(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        mode: enum { searchForNode, searchForUAShadowDOM, captureAreaScreenshot, none },
    })) orelse return error.InvalidParams;

    if (params.mode != .none) {
        log.debug(.not_implemented, "Overlay.setInspectMode", .{ .param = "mode", .value = @tagName(params.mode) });
    }
    return cmd.sendResult(null, .{});
}

// https://chromedevtools.github.io/devtools-protocol/tot/Overlay/#method-setShowViewportSizeOnResize
fn setShowViewportSizeOnResize(cmd: *CDP.Command) !void {
    _ = (try cmd.params(struct {
        show: bool,
    })) orelse return error.InvalidParams;
    return cmd.sendResult(null, .{});
}

const testing = @import("../testing.zig");

test "cdp.overlay: enable, disable and hideHighlight" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A" });

    try ctx.processMessage(.{ .id = 1, .method = "Overlay.enable" });
    try ctx.expectSentResult(null, .{ .id = 1 });

    try ctx.processMessage(.{ .id = 2, .method = "Overlay.hideHighlight" });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try ctx.processMessage(.{ .id = 3, .method = "Overlay.disable" });
    try ctx.expectSentResult(null, .{ .id = 3 });
}

test "cdp.overlay: highlightNode" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/dom1.html" });

    // registers the document as nodeId 1
    try ctx.processMessage(.{ .id = 1, .method = "DOM.getDocument" });

    const config = .{ .showInfo = true, .showExtensionLines = true, .showStyles = true };

    try ctx.processMessage(.{
        .id = 2,
        .method = "Overlay.highlightNode",
        .params = .{ .highlightConfig = config, .nodeId = 1 },
    });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Overlay.highlightNode",
        .params = .{ .highlightConfig = config, .backendNodeId = 1 },
    });
    try ctx.expectSentResult(null, .{ .id = 3 });

    try ctx.processMessage(.{
        .id = 4,
        .method = "Overlay.highlightNode",
        .params = .{ .highlightConfig = config, .backendNodeId = 99999 },
    });
    try ctx.expectSentError(-32000, "Could not find node with given id", .{ .id = 4 });

    try ctx.processMessage(.{
        .id = 5,
        .method = "Overlay.highlightNode",
        .params = .{ .highlightConfig = config },
    });
    try ctx.expectSentError(-32000, "Either nodeId, backendNodeId or objectId must be specified", .{ .id = 5 });
}

test "cdp.overlay: no-op methods" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "Overlay.highlightRect",
        .params = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    });
    try ctx.expectSentResult(null, .{ .id = 1 });

    try ctx.processMessage(.{
        .id = 2,
        .method = "Overlay.setInspectMode",
        .params = .{ .mode = "none", .highlightConfig = .{} },
    });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try ctx.processMessage(.{
        .id = 3,
        .method = "Overlay.setShowViewportSizeOnResize",
        .params = .{ .show = true },
    });
    try ctx.expectSentResult(null, .{ .id = 3 });
}
