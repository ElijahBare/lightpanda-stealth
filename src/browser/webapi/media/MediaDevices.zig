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

const EventTarget = @import("../EventTarget.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ MediaDevices, MediaDeviceInfo };
}

// https://w3c.github.io/mediacapture-main/#mediadevices
//
// Like Chrome before the page is granted camera/microphone access: one
// device of each kind, with empty ids and labels. Capture is never granted.
const MediaDevices = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_devices: ?[]const *MediaDeviceInfo = null,

pub fn init(exec: *Execution) !*MediaDevices {
    return exec._factory.eventTarget(MediaDevices{ ._proto = undefined });
}

pub fn asEventTarget(self: *MediaDevices) *EventTarget {
    return self._proto;
}

fn enumerateDevices(self: *MediaDevices, exec: *Execution) !js.Promise {
    const devices = self._devices orelse blk: {
        const kinds = [_][]const u8{ "audioinput", "videoinput", "audiooutput" };
        const list = try exec.page_arena.alloc(*MediaDeviceInfo, kinds.len);
        for (kinds, list) |kind, *d| {
            d.* = try exec._factory.create(MediaDeviceInfo{ ._kind = kind });
        }
        self._devices = list;
        break :blk list;
    };
    return exec.js.local.?.resolvePromise(devices);
}

fn getUserMedia(_: *MediaDevices, _: ?js.Value) !js.Promise {
    return error.NotAllowedError;
}

fn getDisplayMedia(_: *MediaDevices, _: ?js.Value) !js.Promise {
    return error.NotAllowedError;
}

fn getSupportedConstraints(_: *const MediaDevices) struct {
    aspectRatio: bool = true,
    autoGainControl: bool = true,
    channelCount: bool = true,
    deviceId: bool = true,
    displaySurface: bool = true,
    echoCancellation: bool = true,
    facingMode: bool = true,
    frameRate: bool = true,
    groupId: bool = true,
    height: bool = true,
    latency: bool = true,
    noiseSuppression: bool = true,
    resizeMode: bool = true,
    sampleRate: bool = true,
    sampleSize: bool = true,
    suppressLocalAudioPlayback: bool = true,
    voiceIsolation: bool = true,
    width: bool = true,
} {
    return .{};
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MediaDevices);

    pub const Meta = struct {
        pub const name = "MediaDevices";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const enumerateDevices = bridge.function(MediaDevices.enumerateDevices, .{});
    pub const getUserMedia = bridge.function(MediaDevices.getUserMedia, .{});
    pub const getDisplayMedia = bridge.function(MediaDevices.getDisplayMedia, .{});
    pub const getSupportedConstraints = bridge.function(MediaDevices.getSupportedConstraints, .{});
    pub const ondevicechange = EventTarget.handlerAccessor(MediaDevices, "devicechange");
};

// https://w3c.github.io/mediacapture-main/#device-info
pub const MediaDeviceInfo = struct {
    _kind: []const u8,

    fn getDeviceId(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }
    fn getKind(self: *const MediaDeviceInfo) []const u8 {
        return self._kind;
    }
    fn getLabel(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }
    fn getGroupId(_: *const MediaDeviceInfo) []const u8 {
        return "";
    }

    fn toJSON(self: *const MediaDeviceInfo) struct {
        deviceId: []const u8,
        kind: []const u8,
        label: []const u8,
        groupId: []const u8,
    } {
        return .{ .deviceId = "", .kind = self._kind, .label = "", .groupId = "" };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaDeviceInfo);

        pub const Meta = struct {
            pub const name = "MediaDeviceInfo";
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const deviceId = bridge.accessor(MediaDeviceInfo.getDeviceId, null, .{});
        pub const kind = bridge.accessor(MediaDeviceInfo.getKind, null, .{});
        pub const label = bridge.accessor(MediaDeviceInfo.getLabel, null, .{});
        pub const groupId = bridge.accessor(MediaDeviceInfo.getGroupId, null, .{});
        pub const toJSON = bridge.function(MediaDeviceInfo.toJSON, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: MediaDevices" {
    try testing.htmlRunner("media/media_devices.html", .{});
}
