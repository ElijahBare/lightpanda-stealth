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

const js = @import("../../js/js.zig");

// Interface object only: getContext("webgl2") returns null, so no instance
// is ever created. This matches Chrome launched with --disable-webgl, where
// WebGLRenderingContext and WebGL2RenderingContext still exist on window
// but no context can be obtained.
const WebGL2RenderingContext = @This();

_: u8 = 0,

fn getParameter(_: *const WebGL2RenderingContext, _: u32) ?[]const u8 {
    return null;
}

fn getExtension(_: *const WebGL2RenderingContext, _: []const u8) ?js.Object {
    return null;
}

fn getSupportedExtensions(_: *const WebGL2RenderingContext) ?[]const []const u8 {
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebGL2RenderingContext);

    pub const Meta = struct {
        pub const name = "WebGL2RenderingContext";

        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getParameter = bridge.function(WebGL2RenderingContext.getParameter, .{});
    pub const getExtension = bridge.function(WebGL2RenderingContext.getExtension, .{});
    pub const getSupportedExtensions = bridge.function(WebGL2RenderingContext.getSupportedExtensions, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGL disabled" {
    try testing.htmlRunner("canvas/webgl_disabled.html", .{});
}
