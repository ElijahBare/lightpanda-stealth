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

const Execution = js.Execution;

// https://w3c.github.io/webrtc-pc/#rtcsessiondescription-class
const RTCSessionDescription = @This();

_type: SdpType,
_sdp: []const u8,

pub const SdpType = enum {
    offer,
    pranswer,
    answer,
    rollback,
    pub const js_enum_from_string = true;
};

pub const Init = struct {
    sdp: []const u8 = "",
    type: SdpType,
};

fn init(desc: Init, exec: *const Execution) !*RTCSessionDescription {
    return create(desc.type, desc.sdp, exec);
}

pub fn create(typ: SdpType, sdp: []const u8, exec: *const Execution) !*RTCSessionDescription {
    return exec._factory.create(RTCSessionDescription{
        ._type = typ,
        ._sdp = try exec.page_arena.dupe(u8, sdp),
    });
}

pub fn getType(self: *const RTCSessionDescription) []const u8 {
    return @tagName(self._type);
}

pub fn getSdp(self: *const RTCSessionDescription) []const u8 {
    return self._sdp;
}

fn toJSON(self: *const RTCSessionDescription) struct { type: []const u8, sdp: []const u8 } {
    return .{ .type = self.getType(), .sdp = self._sdp };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCSessionDescription);

    pub const Meta = struct {
        pub const name = "RTCSessionDescription";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(RTCSessionDescription.init, .{});
    pub const @"type" = bridge.accessor(RTCSessionDescription.getType, null, .{});
    pub const sdp = bridge.accessor(RTCSessionDescription.getSdp, null, .{});
    pub const toJSON = bridge.function(RTCSessionDescription.toJSON, .{});
};
