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

// https://w3c.github.io/webrtc-pc/#rtcpeerconnectioniceevent

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");
const RTCIceCandidate = @import("RTCIceCandidate.zig");

const String = lp.String;

const RTCPeerConnectionIceEvent = @This();

pub const Proto = Event;

_proto: *Event,
// page-lifetime, no ref needed
_candidate: ?*RTCIceCandidate,
_url: ?[]const u8,

const Options = Event.inheritOptions(RTCPeerConnectionIceEvent, struct {
    candidate: ?*RTCIceCandidate = null,
    url: ?[]const u8 = null,
});

fn constructor(typ: []const u8, options_: ?Options, page: *Page) !*RTCPeerConnectionIceEvent {
    const arena = try page.getArena(.tiny, "RTCPeerConnectionIceEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    const options = options_ orelse Options{};
    const url = if (options.url) |u| try arena.allocator().dupe(u8, u) else null;
    return initWithTrusted(arena, type_string, options, url, false, page);
}

pub fn initTrusted(candidate: ?*RTCIceCandidate, page: *Page) !*RTCPeerConnectionIceEvent {
    const arena = try page.getArena(.tiny, "RTCPeerConnectionIceEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, comptime .wrap("icecandidate"), .{ .candidate = candidate }, null, true, page);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, options: Options, url: ?[]const u8, trusted: bool, page: *Page) !*RTCPeerConnectionIceEvent {
    const event = try page.factory.event(arena, typ, RTCPeerConnectionIceEvent{
        ._proto = undefined,
        ._candidate = options.candidate,
        ._url = url,
    });
    Event.populatePrototypes(event, options, trusted);
    return event;
}

pub fn asEvent(self: *RTCPeerConnectionIceEvent) *Event {
    return self._proto;
}

fn getCandidate(self: *const RTCPeerConnectionIceEvent) ?*RTCIceCandidate {
    return self._candidate;
}

fn getUrl(self: *const RTCPeerConnectionIceEvent) ?[]const u8 {
    return self._url;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCPeerConnectionIceEvent);

    pub const Meta = struct {
        pub const name = "RTCPeerConnectionIceEvent";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(RTCPeerConnectionIceEvent.constructor, .{});
    pub const candidate = bridge.accessor(RTCPeerConnectionIceEvent.getCandidate, null, .{});
    pub const url = bridge.accessor(RTCPeerConnectionIceEvent.getUrl, null, .{});
};
