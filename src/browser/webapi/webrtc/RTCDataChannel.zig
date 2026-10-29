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

const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");

const log = lp.log;
const Execution = js.Execution;

// https://w3c.github.io/webrtc-pc/#rtcdatachannel
//
// Created by RTCPeerConnection.createDataChannel. No SCTP transport is ever
// established (ICE never connects), so a channel stays "connecting" until it
// is closed, and send() always fails.
const RTCDataChannel = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_exec: *Execution,
_label: []const u8,
_protocol: []const u8,
_ordered: bool,
_negotiated: bool,
_id: ?u16,
_max_packet_life_time: ?u16,
_max_retransmits: ?u16,
_ready_state: ReadyState = .connecting,
_binary_type: BinaryType = .arraybuffer,
_buffered_amount_low_threshold: u32 = 0,

const ReadyState = enum { connecting, open, closing, closed };
const BinaryType = enum { blob, arraybuffer };

pub const Init = struct {
    id: ?u16 = null,
    maxPacketLifeTime: ?u16 = null,
    maxRetransmits: ?u16 = null,
    negotiated: bool = false,
    ordered: bool = true,
    protocol: []const u8 = "",
};

pub fn create(label: []const u8, opts: Init, exec: *Execution) !*RTCDataChannel {
    if (label.len > 65535 or opts.protocol.len > 65535) {
        return exec.js.typeError("Failed to execute 'createDataChannel' on 'RTCPeerConnection': RTCDataChannel label or protocol too long");
    }
    if (opts.maxPacketLifeTime != null and opts.maxRetransmits != null) {
        return exec.js.typeError("Failed to execute 'createDataChannel' on 'RTCPeerConnection': RTCDataChannelInit can not have both maxRetransmits and maxPacketLifeTime");
    }
    if (opts.negotiated and opts.id == null) {
        return exec.js.typeError("Failed to execute 'createDataChannel' on 'RTCPeerConnection': RTCDataChannelInit with negotiated set requires an id");
    }
    if (opts.id) |id| {
        if (id > 65534) {
            return exec.js.typeError("Failed to execute 'createDataChannel' on 'RTCPeerConnection': RTCDataChannel is out of range");
        }
    }

    return exec._factory.eventTarget(RTCDataChannel{
        ._proto = undefined,
        ._exec = exec,
        ._label = try exec.page_arena.dupe(u8, label),
        ._protocol = try exec.page_arena.dupe(u8, opts.protocol),
        ._ordered = opts.ordered,
        ._negotiated = opts.negotiated,
        // Until the SCTP transport is up, only negotiated channels have an id.
        ._id = if (opts.negotiated) opts.id else null,
        ._max_packet_life_time = opts.maxPacketLifeTime,
        ._max_retransmits = opts.maxRetransmits,
    });
}

pub fn asEventTarget(self: *RTCDataChannel) *EventTarget {
    return self._proto;
}

fn getLabel(self: *const RTCDataChannel) []const u8 {
    return self._label;
}
fn getProtocol(self: *const RTCDataChannel) []const u8 {
    return self._protocol;
}
fn getOrdered(self: *const RTCDataChannel) bool {
    return self._ordered;
}
fn getNegotiated(self: *const RTCDataChannel) bool {
    return self._negotiated;
}
fn getId(self: *const RTCDataChannel) ?u16 {
    return self._id;
}
fn getMaxPacketLifeTime(self: *const RTCDataChannel) ?u16 {
    return self._max_packet_life_time;
}
fn getMaxRetransmits(self: *const RTCDataChannel) ?u16 {
    return self._max_retransmits;
}
fn getReadyState(self: *const RTCDataChannel) []const u8 {
    return @tagName(self._ready_state);
}
fn getBufferedAmount(_: *const RTCDataChannel) u32 {
    return 0;
}
fn getBufferedAmountLowThreshold(self: *const RTCDataChannel) u32 {
    return self._buffered_amount_low_threshold;
}
fn setBufferedAmountLowThreshold(self: *RTCDataChannel, value: u32) void {
    self._buffered_amount_low_threshold = value;
}
fn getBinaryType(self: *const RTCDataChannel) []const u8 {
    return @tagName(self._binary_type);
}
// An enum attribute ignores values outside the enum.
fn setBinaryType(self: *RTCDataChannel, value: []const u8) void {
    self._binary_type = std.meta.stringToEnum(BinaryType, value) orelse return;
}

fn send(self: *RTCDataChannel, _: js.Value) !void {
    _ = self;
    // Never "open": the spec's send() throws InvalidStateError otherwise.
    return error.InvalidStateError;
}

pub fn close(self: *RTCDataChannel) !void {
    switch (self._ready_state) {
        .closing, .closed => return,
        .connecting, .open => {},
    }
    self._ready_state = .closing;

    const task = try self._exec._factory.create(CloseTask{ .channel = self });
    try self._exec.js.scheduler.add(task, CloseTask.run, 0, .{
        .name = "RTCDataChannel.close",
        .finalizer = CloseTask.cancelled,
    });
}

// RTCPeerConnection.close(): the channel closes at once, without events.
pub fn closeSilently(self: *RTCDataChannel) void {
    self._ready_state = .closed;
}

const CloseTask = struct {
    channel: *RTCDataChannel,

    fn cancelled(ctx: *anyopaque) void {
        const self: *CloseTask = @ptrCast(@alignCast(ctx));
        self.channel._exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *CloseTask = @ptrCast(@alignCast(ctx));
        const channel = self.channel;
        defer channel._exec._factory.destroy(self);

        if (channel._ready_state == .closed) {
            return null;
        }
        channel._ready_state = .closed;
        channel.fire("close");
        return null;
    }
};

fn fire(self: *RTCDataChannel, comptime typ: []const u8) void {
    const exec = self._exec;
    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, typ)) {
        return;
    }
    const event = Event.initTrusted(.wrap(typ), .{}, exec.page) catch |err| {
        log.warn(.js, "RTCDataChannel event", .{ .err = err, .type = typ });
        return;
    };
    exec.dispatch(target, event, .{ .context = "RTCDataChannel event" }) catch |err| {
        log.debug(.js, "RTCDataChannel event", .{ .err = err, .type = typ });
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCDataChannel);

    pub const Meta = struct {
        pub const name = "RTCDataChannel";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const label = bridge.accessor(RTCDataChannel.getLabel, null, .{});
    pub const ordered = bridge.accessor(RTCDataChannel.getOrdered, null, .{});
    pub const maxPacketLifeTime = bridge.accessor(RTCDataChannel.getMaxPacketLifeTime, null, .{});
    pub const maxRetransmits = bridge.accessor(RTCDataChannel.getMaxRetransmits, null, .{});
    pub const protocol = bridge.accessor(RTCDataChannel.getProtocol, null, .{});
    pub const negotiated = bridge.accessor(RTCDataChannel.getNegotiated, null, .{});
    pub const id = bridge.accessor(RTCDataChannel.getId, null, .{});
    pub const readyState = bridge.accessor(RTCDataChannel.getReadyState, null, .{});
    pub const bufferedAmount = bridge.accessor(RTCDataChannel.getBufferedAmount, null, .{});
    pub const bufferedAmountLowThreshold = bridge.accessor(RTCDataChannel.getBufferedAmountLowThreshold, RTCDataChannel.setBufferedAmountLowThreshold, .{});
    pub const binaryType = bridge.accessor(RTCDataChannel.getBinaryType, RTCDataChannel.setBinaryType, .{});

    pub const send = bridge.function(RTCDataChannel.send, .{});
    pub const close = bridge.function(RTCDataChannel.close, .{});

    pub const onopen = EventTarget.handlerAccessor(RTCDataChannel, "open");
    pub const onbufferedamountlow = EventTarget.handlerAccessor(RTCDataChannel, "bufferedamountlow");
    pub const onerror = EventTarget.handlerAccessor(RTCDataChannel, "error");
    pub const onclosing = EventTarget.handlerAccessor(RTCDataChannel, "closing");
    pub const onclose = EventTarget.handlerAccessor(RTCDataChannel, "close");
    pub const onmessage = EventTarget.handlerAccessor(RTCDataChannel, "message");
};
