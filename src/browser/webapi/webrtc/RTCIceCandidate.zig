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

const js = @import("../../js/js.zig");

const Execution = js.Execution;

// https://w3c.github.io/webrtc-pc/#rtcicecandidate-interface
const RTCIceCandidate = @This();

_candidate: []const u8,
_sdp_mid: ?[]const u8,
_sdp_m_line_index: ?u16,
_username_fragment: ?[]const u8,

// Parsed from `_candidate`; all null when it doesn't parse.
_foundation: ?[]const u8 = null,
_component: ?[]const u8 = null,
_priority: ?u32 = null,
_address: ?[]const u8 = null,
_protocol: ?[]const u8 = null,
_port: ?u16 = null,
_type: ?[]const u8 = null,
_tcp_type: ?[]const u8 = null,
_related_address: ?[]const u8 = null,
_related_port: ?u16 = null,

pub const Init = struct {
    candidate: []const u8 = "",
    sdpMLineIndex: ?u16 = null,
    sdpMid: ?[]const u8 = null,
    usernameFragment: ?[]const u8 = null,
};

fn init(init_: ?Init, exec: *const Execution) !*RTCIceCandidate {
    const opts = init_ orelse Init{};
    if (opts.sdpMid == null and opts.sdpMLineIndex == null) {
        return exec.js.typeError("Failed to construct 'RTCIceCandidate': sdpMid and sdpMLineIndex are both null.");
    }
    return create(opts, exec);
}

pub fn create(opts: Init, exec: *const Execution) !*RTCIceCandidate {
    const arena = exec.page_arena;
    const candidate = try arena.dupe(u8, opts.candidate);
    var self = RTCIceCandidate{
        ._candidate = candidate,
        ._sdp_mid = if (opts.sdpMid) |m| try arena.dupe(u8, m) else null,
        ._sdp_m_line_index = opts.sdpMLineIndex,
        ._username_fragment = if (opts.usernameFragment) |u| try arena.dupe(u8, u) else null,
    };
    self.parse(candidate);
    return exec._factory.create(self);
}

// candidate:<foundation> <component> <protocol> <priority> <address> <port>
//   typ <type> [raddr <addr>] [rport <port>] [tcptype <t>] [ufrag <u>] ...
fn parse(self: *RTCIceCandidate, candidate: []const u8) void {
    var line = candidate;
    if (std.mem.startsWith(u8, line, "a=")) line = line[2..];
    if (!std.mem.startsWith(u8, line, "candidate:")) return;
    line = line["candidate:".len..];

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const foundation = it.next() orelse return;
    const component = it.next() orelse return;
    const protocol = it.next() orelse return;
    const priority = std.fmt.parseUnsigned(u32, it.next() orelse return, 10) catch return;
    const address = it.next() orelse return;
    const port = std.fmt.parseUnsigned(u16, it.next() orelse return, 10) catch return;
    if (!std.mem.eql(u8, it.next() orelse return, "typ")) return;
    const typ = it.next() orelse return;

    self._foundation = foundation;
    self._component = if (std.mem.eql(u8, component, "1")) "rtp" else if (std.mem.eql(u8, component, "2")) "rtcp" else null;
    self._protocol = if (std.ascii.eqlIgnoreCase(protocol, "udp")) "udp" else if (std.ascii.eqlIgnoreCase(protocol, "tcp")) "tcp" else null;
    self._priority = priority;
    self._address = address;
    self._port = port;
    self._type = typ;

    while (it.next()) |key| {
        const value = it.next() orelse break;
        if (std.mem.eql(u8, key, "raddr")) {
            self._related_address = value;
        } else if (std.mem.eql(u8, key, "rport")) {
            self._related_port = std.fmt.parseUnsigned(u16, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "tcptype")) {
            self._tcp_type = value;
        } else if (std.mem.eql(u8, key, "ufrag")) {
            if (self._username_fragment == null) self._username_fragment = value;
        }
    }
}

pub fn getCandidate(self: *const RTCIceCandidate) []const u8 {
    return self._candidate;
}
pub fn getSdpMid(self: *const RTCIceCandidate) ?[]const u8 {
    return self._sdp_mid;
}
pub fn getSdpMLineIndex(self: *const RTCIceCandidate) ?u16 {
    return self._sdp_m_line_index;
}
pub fn getUsernameFragment(self: *const RTCIceCandidate) ?[]const u8 {
    return self._username_fragment;
}
fn getFoundation(self: *const RTCIceCandidate) ?[]const u8 {
    return self._foundation;
}
fn getComponent(self: *const RTCIceCandidate) ?[]const u8 {
    return self._component;
}
fn getPriority(self: *const RTCIceCandidate) ?u32 {
    return self._priority;
}
pub fn getAddress(self: *const RTCIceCandidate) ?[]const u8 {
    return self._address;
}
fn getProtocol(self: *const RTCIceCandidate) ?[]const u8 {
    return self._protocol;
}
fn getPort(self: *const RTCIceCandidate) ?u16 {
    return self._port;
}
pub fn getType(self: *const RTCIceCandidate) ?[]const u8 {
    return self._type;
}
fn getTcpType(self: *const RTCIceCandidate) ?[]const u8 {
    return self._tcp_type;
}
fn getRelatedAddress(self: *const RTCIceCandidate) ?[]const u8 {
    return self._related_address;
}
fn getRelatedPort(self: *const RTCIceCandidate) ?u16 {
    return self._related_port;
}

fn toJSON(self: *const RTCIceCandidate) struct {
    candidate: []const u8,
    sdpMid: ?[]const u8,
    sdpMLineIndex: ?u16,
    usernameFragment: ?[]const u8,
} {
    return .{
        .candidate = self._candidate,
        .sdpMid = self._sdp_mid,
        .sdpMLineIndex = self._sdp_m_line_index,
        .usernameFragment = self._username_fragment,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCIceCandidate);

    pub const Meta = struct {
        pub const name = "RTCIceCandidate";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(RTCIceCandidate.init, .{});
    pub const candidate = bridge.accessor(RTCIceCandidate.getCandidate, null, .{});
    pub const sdpMid = bridge.accessor(RTCIceCandidate.getSdpMid, null, .{});
    pub const sdpMLineIndex = bridge.accessor(RTCIceCandidate.getSdpMLineIndex, null, .{});
    pub const foundation = bridge.accessor(RTCIceCandidate.getFoundation, null, .{});
    pub const component = bridge.accessor(RTCIceCandidate.getComponent, null, .{});
    pub const priority = bridge.accessor(RTCIceCandidate.getPriority, null, .{});
    pub const address = bridge.accessor(RTCIceCandidate.getAddress, null, .{});
    pub const protocol = bridge.accessor(RTCIceCandidate.getProtocol, null, .{});
    pub const port = bridge.accessor(RTCIceCandidate.getPort, null, .{});
    pub const @"type" = bridge.accessor(RTCIceCandidate.getType, null, .{});
    pub const tcpType = bridge.accessor(RTCIceCandidate.getTcpType, null, .{});
    pub const relatedAddress = bridge.accessor(RTCIceCandidate.getRelatedAddress, null, .{});
    pub const relatedPort = bridge.accessor(RTCIceCandidate.getRelatedPort, null, .{});
    pub const usernameFragment = bridge.accessor(RTCIceCandidate.getUsernameFragment, null, .{});
    pub const toJSON = bridge.function(RTCIceCandidate.toJSON, .{});
};
