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

const RTCDataChannel = @import("RTCDataChannel.zig");
const RTCIceCandidate = @import("RTCIceCandidate.zig");
const RTCSessionDescription = @import("RTCSessionDescription.zig");
const RTCPeerConnectionIceEvent = @import("RTCPeerConnectionIceEvent.zig");

const log = lp.log;
const Execution = js.Execution;
const SdpType = RTCSessionDescription.SdpType;

pub fn registerTypes() []const type {
    return &.{
        RTCPeerConnection,
        RTCSessionDescription,
        RTCIceCandidate,
        RTCDataChannel,
        RTCPeerConnectionIceEvent,
    };
}

// https://w3c.github.io/webrtc-pc/#rtcpeerconnection-interface
//
// Behaves like Chrome launched with
// `--webrtc-ip-handling-policy=disable_non_proxied_udp`: offers and answers
// are real-looking SDP, but ICE gathering never touches the network. It
// yields at most one TCP host candidate whose address is a random mDNS name
// (as Chrome's mDNS obfuscation does), never a srflx/relay candidate or an
// IP, then completes. ICE never connects, so data channels never open.
const RTCPeerConnection = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_exec: *Execution,
_config: Configuration,
_signaling_state: SignalingState = .stable,
_ice_gathering_state: IceGatheringState = .new,
_closed: bool = false,
_gathering_scheduled: bool = false,
_negotiation_needed_scheduled: bool = false,

_current_local: ?*RTCSessionDescription = null,
_pending_local: ?*RTCSessionDescription = null,
_current_remote: ?*RTCSessionDescription = null,
_pending_remote: ?*RTCSessionDescription = null,
_last_offer: ?[]const u8 = null,
_last_answer: ?[]const u8 = null,

// m-sections this side offers, in order. Sticky, like transceivers.
_offer_audio: bool = false,
_offer_video: bool = false,
_data_channels: std.ArrayList(*RTCDataChannel) = .empty,

// Per-connection ICE/DTLS identity, stable across offers.
_session_id: u64,
_ice_ufrag: [4]u8,
_ice_pwd: [24]u8,
_fingerprint: [32 * 3 - 1]u8,
_mdns_host: [36 + ".local".len]u8,
_foundation: u32,

const SignalingState = enum {
    stable,
    @"have-local-offer",
    @"have-remote-offer",
    @"have-local-pranswer",
    @"have-remote-pranswer",
    closed,
};

const IceGatheringState = enum { new, gathering, complete };

const BundlePolicy = enum {
    balanced,
    @"max-compat",
    @"max-bundle",
    pub const js_enum_from_string = true;
};

const IceTransportPolicy = enum {
    relay,
    all,
    pub const js_enum_from_string = true;
};

const RtcpMuxPolicy = enum {
    require,
    pub const js_enum_from_string = true;
};

const Urls = union(enum) {
    one: []const u8,
    many: []const []const u8,
};

const IceServer = struct {
    credential: ?[]const u8 = null,
    urls: Urls,
    username: ?[]const u8 = null,
};

const Configuration = struct {
    bundlePolicy: BundlePolicy = .balanced,
    iceCandidatePoolSize: u8 = 0,
    iceServers: []const IceServer = &.{},
    iceTransportPolicy: IceTransportPolicy = .all,
    rtcpMuxPolicy: RtcpMuxPolicy = .require,
};

const OfferOptions = struct {
    iceRestart: bool = false,
    offerToReceiveAudio: ?js.Value = null,
    offerToReceiveVideo: ?js.Value = null,
};

const SessionDescriptionInit = struct {
    sdp: []const u8 = "",
    type: ?SdpType = null,
};

fn init(config_: ?Configuration, exec: *Execution) !*RTCPeerConnection {
    const config = try copyConfiguration(config_ orelse Configuration{}, exec);

    var session_id_bytes: [8]u8 = undefined;
    lp.io.random(&session_id_bytes);
    // Chrome's session ids are positive int64s.
    const session_id = std.mem.readInt(u64, &session_id_bytes, .little) & 0x7fff_ffff_ffff_ffff;

    var foundation_bytes: [4]u8 = undefined;
    lp.io.random(&foundation_bytes);

    var self = RTCPeerConnection{
        ._proto = undefined,
        ._exec = exec,
        ._config = config,
        ._session_id = session_id,
        ._ice_ufrag = undefined,
        ._ice_pwd = undefined,
        ._fingerprint = undefined,
        ._mdns_host = undefined,
        ._foundation = std.mem.readInt(u32, &foundation_bytes, .little),
    };
    randomIceChars(&self._ice_ufrag);
    randomIceChars(&self._ice_pwd);
    randomFingerprint(&self._fingerprint);
    @import("../../../id.zig").uuidv4(self._mdns_host[0..36]);
    @memcpy(self._mdns_host[36..], ".local");

    return exec._factory.eventTarget(self);
}

// Validates like Chrome, and copies into the page arena: the input lives in
// the call arena.
fn copyConfiguration(config: Configuration, exec: *Execution) !Configuration {
    const arena = exec.page_arena;
    const servers = try arena.alloc(IceServer, config.iceServers.len);
    for (config.iceServers, servers) |server, *out| {
        var one: [1][]const u8 = undefined;
        const urls: []const []const u8 = switch (server.urls) {
            .one => |u| blk: {
                one[0] = u;
                break :blk &one;
            },
            .many => |m| m,
        };
        if (urls.len == 0) {
            return error.SyntaxError;
        }
        for (urls) |url| {
            const is_turn = std.mem.startsWith(u8, url, "turn:") or std.mem.startsWith(u8, url, "turns:");
            const is_stun = std.mem.startsWith(u8, url, "stun:") or std.mem.startsWith(u8, url, "stuns:");
            if (!is_turn and !is_stun) {
                return error.SyntaxError;
            }
            if (is_turn and (server.username == null or server.credential == null)) {
                return error.InvalidAccessError;
            }
        }
        out.* = .{
            .credential = if (server.credential) |c| try arena.dupe(u8, c) else null,
            .username = if (server.username) |u| try arena.dupe(u8, u) else null,
            .urls = switch (server.urls) {
                .one => |u| .{ .one = try arena.dupe(u8, u) },
                .many => |m| blk: {
                    const copy = try arena.alloc([]const u8, m.len);
                    for (m, copy) |u, *c| c.* = try arena.dupe(u8, u);
                    break :blk .{ .many = copy };
                },
            },
        };
    }
    var copy = config;
    copy.iceServers = servers;
    return copy;
}

fn randomIceChars(out: []u8) void {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    lp.io.random(out);
    for (out) |*c| c.* = alphabet[c.* & 63];
}

fn randomFingerprint(out: *[32 * 3 - 1]u8) void {
    const hex = "0123456789ABCDEF";
    var bytes: [32]u8 = undefined;
    lp.io.random(&bytes);
    for (bytes, 0..) |b, i| {
        out[i * 3] = hex[b >> 4];
        out[i * 3 + 1] = hex[b & 0x0f];
        if (i < 31) out[i * 3 + 2] = ':';
    }
}

pub fn asEventTarget(self: *RTCPeerConnection) *EventTarget {
    return self._proto;
}

// === SDP ===

const MediaKind = enum { audio, video, application };

const Section = struct {
    kind: MediaKind,
    mid: []const u8,
    direction: []const u8 = "recvonly",
};

fn writeSdp(self: *const RTCPeerConnection, sections: []const Section, setup: []const u8, exec: *const Execution) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(exec.call_arena);
    const w = &buf.writer;

    try w.print("v=0\r\no=- {d} 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n", .{self._session_id});
    if (sections.len > 0) {
        try w.writeAll("a=group:BUNDLE");
        for (sections) |s| try w.print(" {s}", .{s.mid});
        try w.writeAll("\r\n");
    }
    try w.writeAll("a=extmap-allow-mixed\r\na=msid-semantic: WMS\r\n");

    for (sections) |s| {
        switch (s.kind) {
            .audio => try w.writeAll("m=audio 9 UDP/TLS/RTP/SAVPF 111 0 8\r\nc=IN IP4 0.0.0.0\r\na=rtcp:9 IN IP4 0.0.0.0\r\n"),
            .video => try w.writeAll("m=video 9 UDP/TLS/RTP/SAVPF 96 97\r\nc=IN IP4 0.0.0.0\r\na=rtcp:9 IN IP4 0.0.0.0\r\n"),
            .application => try w.writeAll("m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 0.0.0.0\r\n"),
        }
        try w.print("a=ice-ufrag:{s}\r\na=ice-pwd:{s}\r\na=ice-options:trickle\r\na=fingerprint:sha-256 {s}\r\na=setup:{s}\r\na=mid:{s}\r\n", .{
            &self._ice_ufrag,
            &self._ice_pwd,
            &self._fingerprint,
            setup,
            s.mid,
        });
        switch (s.kind) {
            .audio => try w.print(
                "a={s}\r\na=rtcp-mux\r\na=rtpmap:111 opus/48000/2\r\na=rtcp-fb:111 transport-cc\r\na=fmtp:111 minptime=10;useinbandfec=1\r\na=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\n",
                .{s.direction},
            ),
            .video => try w.print(
                "a={s}\r\na=rtcp-mux\r\na=rtcp-rsize\r\na=rtpmap:96 VP8/90000\r\na=rtcp-fb:96 goog-remb\r\na=rtcp-fb:96 transport-cc\r\na=rtcp-fb:96 ccm fir\r\na=rtcp-fb:96 nack\r\na=rtcp-fb:96 nack pli\r\na=rtpmap:97 rtx/90000\r\na=fmtp:97 apt=96\r\n",
                .{s.direction},
            ),
            .application => try w.writeAll("a=sctp-port:5000\r\na=max-message-size:262144\r\n"),
        }
    }
    return buf.written();
}

fn offerSections(self: *const RTCPeerConnection, exec: *const Execution) ![]const Section {
    var sections: std.ArrayList(Section) = .empty;
    const mids = [_][]const u8{ "0", "1", "2" };
    if (self._offer_audio) {
        try sections.append(exec.call_arena, .{ .kind = .audio, .mid = mids[sections.items.len] });
    }
    if (self._offer_video) {
        try sections.append(exec.call_arena, .{ .kind = .video, .mid = mids[sections.items.len] });
    }
    if (self._data_channels.items.len > 0) {
        try sections.append(exec.call_arena, .{ .kind = .application, .mid = mids[sections.items.len] });
    }
    return sections.items;
}

// One answer section per m-line of the remote offer, with its mid.
fn answerSections(remote_sdp: []const u8, exec: *const Execution) ![]const Section {
    var sections: std.ArrayList(Section) = .empty;
    var lines = std.mem.tokenizeAny(u8, remote_sdp, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "m=")) {
            const kind: MediaKind = if (std.mem.startsWith(u8, line, "m=audio"))
                .audio
            else if (std.mem.startsWith(u8, line, "m=video"))
                .video
            else
                .application;
            try sections.append(exec.call_arena, .{
                .kind = kind,
                .mid = try std.fmt.allocPrint(exec.call_arena, "{d}", .{sections.items.len}),
                .direction = "inactive",
            });
            continue;
        }
        if (sections.items.len == 0) continue;
        const current = &sections.items[sections.items.len - 1];
        if (std.mem.startsWith(u8, line, "a=mid:")) {
            current.mid = line["a=mid:".len..];
        } else if (std.mem.eql(u8, line, "a=sendrecv") or std.mem.eql(u8, line, "a=sendonly")) {
            // we have nothing to send back
            current.direction = "recvonly";
        }
    }
    return sections.items;
}

fn hasMediaSection(sdp: []const u8) bool {
    return std.mem.startsWith(u8, sdp, "m=") or std.mem.indexOf(u8, sdp, "\nm=") != null;
}

fn isSdp(sdp: []const u8) bool {
    return std.mem.startsWith(u8, sdp, "v=");
}

// === Offer / answer ===

fn createOffer(self: *RTCPeerConnection, options_: ?OfferOptions, exec: *Execution) !js.Promise {
    if (self._closed) {
        return error.InvalidStateError;
    }
    if (options_) |options| {
        if (options.offerToReceiveAudio) |v| {
            if (v.toBool()) self._offer_audio = true;
        }
        if (options.offerToReceiveVideo) |v| {
            if (v.toBool()) self._offer_video = true;
        }
    }
    const sdp = try self.writeSdp(try self.offerSections(exec), "actpass", exec);
    self._last_offer = try exec.page_arena.dupe(u8, sdp);
    const desc = try RTCSessionDescription.create(.offer, sdp, exec);
    return exec.js.local.?.resolvePromise(desc);
}

fn createAnswer(self: *RTCPeerConnection, _: ?js.Value, exec: *Execution) !js.Promise {
    if (self._closed) {
        return error.InvalidStateError;
    }
    const remote = self.getRemoteDescription() orelse return error.InvalidStateError;
    switch (self._signaling_state) {
        .@"have-remote-offer", .@"have-local-pranswer" => {},
        else => return error.InvalidStateError,
    }
    const sdp = try self.writeSdp(try answerSections(remote._sdp, exec), "active", exec);
    self._last_answer = try exec.page_arena.dupe(u8, sdp);
    const desc = try RTCSessionDescription.create(.answer, sdp, exec);
    return exec.js.local.?.resolvePromise(desc);
}

fn setLocalDescription(self: *RTCPeerConnection, init_: ?SessionDescriptionInit, exec: *Execution) !js.Promise {
    if (self._closed) {
        return error.InvalidStateError;
    }
    const desc_init = init_ orelse SessionDescriptionInit{};

    // An absent type means "whatever fits the signaling state" (the
    // parameterless setLocalDescription()).
    const typ: SdpType = desc_init.type orelse switch (self._signaling_state) {
        .stable, .@"have-local-offer", .@"have-remote-pranswer" => .offer,
        else => .answer,
    };

    var sdp = desc_init.sdp;
    if (typ != .rollback and sdp.len == 0) {
        sdp = switch (typ) {
            .offer => self._last_offer orelse blk: {
                const offer = try self.writeSdp(try self.offerSections(exec), "actpass", exec);
                self._last_offer = try exec.page_arena.dupe(u8, offer);
                break :blk offer;
            },
            .answer, .pranswer => self._last_answer orelse blk: {
                const remote = self.getRemoteDescription() orelse return error.InvalidStateError;
                const answer = try self.writeSdp(try answerSections(remote._sdp, exec), "active", exec);
                self._last_answer = try exec.page_arena.dupe(u8, answer);
                break :blk answer;
            },
            .rollback => unreachable,
        };
    }
    if (typ != .rollback and !isSdp(sdp)) {
        return error.OperationError;
    }

    const state = self._signaling_state;
    const next: SignalingState = switch (typ) {
        .offer => switch (state) {
            .stable, .@"have-local-offer" => .@"have-local-offer",
            else => return error.InvalidStateError,
        },
        .pranswer => switch (state) {
            .@"have-remote-offer", .@"have-local-pranswer" => .@"have-local-pranswer",
            else => return error.InvalidStateError,
        },
        .answer => switch (state) {
            .@"have-remote-offer", .@"have-local-pranswer" => .stable,
            else => return error.InvalidStateError,
        },
        .rollback => switch (state) {
            .@"have-local-offer" => .stable,
            else => return error.InvalidStateError,
        },
    };

    switch (typ) {
        .offer, .pranswer => self._pending_local = try RTCSessionDescription.create(typ, sdp, exec),
        .answer => {
            self._current_local = try RTCSessionDescription.create(typ, sdp, exec);
            self._current_remote = self._pending_remote;
            self._pending_local = null;
            self._pending_remote = null;
        },
        .rollback => self._pending_local = null,
    }

    self.setSignalingState(next);
    if (typ != .rollback and hasMediaSection(sdp)) {
        try self.scheduleGathering();
    }
    return exec.js.local.?.resolvePromise(js.Undefined{});
}

fn setRemoteDescription(self: *RTCPeerConnection, desc_init: SessionDescriptionInit, exec: *Execution) !js.Promise {
    if (self._closed) {
        return error.InvalidStateError;
    }
    const typ = desc_init.type orelse return exec.js.typeError("Failed to execute 'setRemoteDescription' on 'RTCPeerConnection': The provided value is not of type 'RTCSessionDescriptionInit'.");
    if (typ != .rollback and !isSdp(desc_init.sdp)) {
        return error.OperationError;
    }

    const state = self._signaling_state;
    const next: SignalingState = switch (typ) {
        .offer => switch (state) {
            .stable, .@"have-remote-offer" => .@"have-remote-offer",
            else => return error.InvalidStateError,
        },
        .pranswer => switch (state) {
            .@"have-local-offer", .@"have-remote-pranswer" => .@"have-remote-pranswer",
            else => return error.InvalidStateError,
        },
        .answer => switch (state) {
            .@"have-local-offer", .@"have-remote-pranswer" => .stable,
            else => return error.InvalidStateError,
        },
        .rollback => switch (state) {
            .@"have-remote-offer" => .stable,
            else => return error.InvalidStateError,
        },
    };

    switch (typ) {
        .offer, .pranswer => {
            self._pending_remote = try RTCSessionDescription.create(typ, desc_init.sdp, exec);
            if (typ == .offer) self._last_answer = null;
        },
        .answer => {
            self._current_remote = try RTCSessionDescription.create(typ, desc_init.sdp, exec);
            self._current_local = self._pending_local;
            self._pending_local = null;
            self._pending_remote = null;
        },
        .rollback => self._pending_remote = null,
    }

    self.setSignalingState(next);
    return exec.js.local.?.resolvePromise(js.Undefined{});
}

fn addIceCandidate(self: *RTCPeerConnection, _: ?js.Value, exec: *Execution) !js.Promise {
    if (self._closed) {
        return error.InvalidStateError;
    }
    if (self.getRemoteDescription() == null) {
        return error.InvalidStateError;
    }
    // Remote candidates are accepted and ignored: we never run connectivity
    // checks.
    return exec.js.local.?.resolvePromise(js.Undefined{});
}

fn setSignalingState(self: *RTCPeerConnection, state: SignalingState) void {
    if (self._signaling_state == state) {
        return;
    }
    self._signaling_state = state;
    self.fire("signalingstatechange");
}

// === Data channels ===

fn createDataChannel(self: *RTCPeerConnection, label: []const u8, opts_: ?RTCDataChannel.Init, exec: *Execution) !*RTCDataChannel {
    if (self._closed) {
        return error.InvalidStateError;
    }
    const channel = try RTCDataChannel.create(label, opts_ orelse RTCDataChannel.Init{}, exec);
    const first = self._data_channels.items.len == 0;
    try self._data_channels.append(exec.page_arena, channel);
    if (first) {
        try self.scheduleNegotiationNeeded();
    }
    return channel;
}

fn scheduleNegotiationNeeded(self: *RTCPeerConnection) !void {
    if (self._negotiation_needed_scheduled) {
        return;
    }
    self._negotiation_needed_scheduled = true;
    try self.schedule(.negotiation_needed);
}

// === ICE gathering ===

fn scheduleGathering(self: *RTCPeerConnection) !void {
    if (self._gathering_scheduled) {
        return;
    }
    self._gathering_scheduled = true;
    try self.schedule(.gather);
}

fn gather(self: *RTCPeerConnection) !void {
    if (self._closed) {
        return;
    }
    const exec = self._exec;

    self._ice_gathering_state = .gathering;
    self.fire("icegatheringstatechange");
    if (self._closed) return;

    // With a relay-only policy (and no TURN reachable) nothing is gathered.
    if (self._config.iceTransportPolicy == .all) {
        const local = self.getLocalDescription();
        const mid = if (local) |l| firstMid(l._sdp) else null;
        const line = try std.fmt.allocPrint(
            exec.page_arena,
            "candidate:{d} 1 tcp 1518280447 {s} 9 typ host tcptype active generation 0 ufrag {s} network-id 1",
            .{ self._foundation, &self._mdns_host, &self._ice_ufrag },
        );
        const candidate = try RTCIceCandidate.create(.{
            .candidate = line,
            .sdpMid = mid orelse "0",
            .sdpMLineIndex = 0,
            .usernameFragment = &self._ice_ufrag,
        }, exec);
        try self.addCandidateToLocalDescription(line);
        self.fireIceCandidate(candidate);
        if (self._closed) return;
    }

    self._ice_gathering_state = .complete;
    self.fire("icegatheringstatechange");
    if (self._closed) return;
    self.fireIceCandidate(null);
}

fn firstMid(sdp: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, sdp, "a=mid:") orelse return null;
    const rest = sdp[start + "a=mid:".len ..];
    const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    return rest[0..end];
}

// Gathered candidates show up in localDescription, in the first (bundled)
// m-section, right after its c= line.
fn addCandidateToLocalDescription(self: *RTCPeerConnection, line: []const u8) !void {
    const slot: *?*RTCSessionDescription = if (self._pending_local != null) &self._pending_local else &self._current_local;
    const desc = slot.* orelse return;
    const sdp = desc._sdp;
    const m = std.mem.indexOf(u8, sdp, "\nm=") orelse return;
    const c_line = "c=IN IP4 0.0.0.0\r\n";
    const c = std.mem.indexOfPos(u8, sdp, m, c_line) orelse return;
    const at = c + c_line.len;

    const exec = self._exec;
    const updated = try std.mem.concat(exec.page_arena, u8, &.{ sdp[0..at], "a=", line, "\r\n", sdp[at..] });
    slot.* = try RTCSessionDescription.create(desc._type, updated, exec);
}

fn fireIceCandidate(self: *RTCPeerConnection, candidate: ?*RTCIceCandidate) void {
    const exec = self._exec;
    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, "icecandidate")) {
        return;
    }
    const event = RTCPeerConnectionIceEvent.initTrusted(candidate, exec.page) catch |err| {
        log.warn(.js, "RTCPeerConnection icecandidate", .{ .err = err });
        return;
    };
    exec.dispatch(target, event.asEvent(), .{ .context = "RTCPeerConnection icecandidate" }) catch |err| {
        log.debug(.js, "RTCPeerConnection icecandidate", .{ .err = err });
    };
}

fn fire(self: *RTCPeerConnection, comptime typ: []const u8) void {
    const exec = self._exec;
    const target = self.asEventTarget();
    if (!exec.hasDirectListeners(target, typ)) {
        return;
    }
    const event = Event.initTrusted(.wrap(typ), .{}, exec.page) catch |err| {
        log.warn(.js, "RTCPeerConnection event", .{ .err = err, .type = typ });
        return;
    };
    exec.dispatch(target, event, .{ .context = "RTCPeerConnection event" }) catch |err| {
        log.debug(.js, "RTCPeerConnection event", .{ .err = err, .type = typ });
    };
}

const TaskKind = enum { gather, negotiation_needed };

const Task = struct {
    pc: *RTCPeerConnection,
    kind: TaskKind,

    fn cancelled(ctx: *anyopaque) void {
        const self: *Task = @ptrCast(@alignCast(ctx));
        self.pc._exec._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *Task = @ptrCast(@alignCast(ctx));
        const pc = self.pc;
        const kind = self.kind;
        pc._exec._factory.destroy(self);

        switch (kind) {
            .gather => pc.gather() catch |err| {
                log.warn(.js, "RTCPeerConnection gather", .{ .err = err });
            },
            .negotiation_needed => {
                pc._negotiation_needed_scheduled = false;
                if (!pc._closed and pc._signaling_state == .stable) {
                    pc.fire("negotiationneeded");
                }
            },
        }
        return null;
    }
};

fn schedule(self: *RTCPeerConnection, kind: TaskKind) !void {
    const exec = self._exec;
    const task = try exec._factory.create(Task{ .pc = self, .kind = kind });
    errdefer exec._factory.destroy(task);
    try exec.js.scheduler.add(task, Task.run, 0, .{
        .name = "RTCPeerConnection",
        .finalizer = Task.cancelled,
    });
}

// === close / state ===

fn close(self: *RTCPeerConnection) void {
    if (self._closed) {
        return;
    }
    self._closed = true;
    // No events: close() is silent, per spec.
    self._signaling_state = .closed;
    for (self._data_channels.items) |channel| {
        channel.closeSilently();
    }
}

fn getLocalDescription(self: *const RTCPeerConnection) ?*RTCSessionDescription {
    return self._pending_local orelse self._current_local;
}
fn getCurrentLocalDescription(self: *const RTCPeerConnection) ?*RTCSessionDescription {
    return self._current_local;
}
fn getPendingLocalDescription(self: *const RTCPeerConnection) ?*RTCSessionDescription {
    return self._pending_local;
}
fn getRemoteDescription(self: *const RTCPeerConnection) ?*RTCSessionDescription {
    return self._pending_remote orelse self._current_remote;
}
fn getCurrentRemoteDescription(self: *const RTCPeerConnection) ?*RTCSessionDescription {
    return self._current_remote;
}
fn getPendingRemoteDescription(self: *const RTCPeerConnection) ?*RTCSessionDescription {
    return self._pending_remote;
}
fn getSignalingState(self: *const RTCPeerConnection) []const u8 {
    return @tagName(self._signaling_state);
}
fn getIceGatheringState(self: *const RTCPeerConnection) []const u8 {
    return @tagName(self._ice_gathering_state);
}
fn getIceConnectionState(self: *const RTCPeerConnection) []const u8 {
    return if (self._closed) "closed" else "new";
}
fn getConnectionState(self: *const RTCPeerConnection) []const u8 {
    return if (self._closed) "closed" else "new";
}
fn getCanTrickleIceCandidates(self: *const RTCPeerConnection) ?bool {
    const remote = self.getRemoteDescription() orelse return null;
    return std.mem.indexOf(u8, remote._sdp, "a=ice-options:trickle") != null;
}
fn getSctp(_: *const RTCPeerConnection) ?js.Object {
    return null;
}

const IceServerOut = struct {
    urls: []const []const u8,
    username: []const u8,
    credential: []const u8,
};

fn getConfiguration(self: *const RTCPeerConnection, exec: *const Execution) !struct {
    iceServers: []const IceServerOut,
    iceTransportPolicy: []const u8,
    bundlePolicy: []const u8,
    rtcpMuxPolicy: []const u8,
    iceCandidatePoolSize: u8,
} {
    const config = self._config;
    const servers = try exec.call_arena.alloc(IceServerOut, config.iceServers.len);
    for (config.iceServers, servers) |server, *out| {
        out.* = .{
            .urls = switch (server.urls) {
                .one => |u| try exec.call_arena.dupe([]const u8, &.{u}),
                .many => |m| m,
            },
            .username = server.username orelse "",
            .credential = server.credential orelse "",
        };
    }
    return .{
        .iceServers = servers,
        .iceTransportPolicy = @tagName(config.iceTransportPolicy),
        .bundlePolicy = @tagName(config.bundlePolicy),
        .rtcpMuxPolicy = @tagName(config.rtcpMuxPolicy),
        .iceCandidatePoolSize = config.iceCandidatePoolSize,
    };
}

fn setConfiguration(self: *RTCPeerConnection, config: Configuration, exec: *Execution) !void {
    if (self._closed) {
        return error.InvalidStateError;
    }
    self._config = try copyConfiguration(config, exec);
}

fn getEmptyList(_: *const RTCPeerConnection) []const js.Object {
    return &.{};
}

fn restartIce(_: *RTCPeerConnection) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(RTCPeerConnection);

    pub const Meta = struct {
        pub const name = "RTCPeerConnection";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(RTCPeerConnection.init, .{});

    pub const createOffer = bridge.function(RTCPeerConnection.createOffer, .{});
    pub const createAnswer = bridge.function(RTCPeerConnection.createAnswer, .{});
    pub const setLocalDescription = bridge.function(RTCPeerConnection.setLocalDescription, .{});
    pub const setRemoteDescription = bridge.function(RTCPeerConnection.setRemoteDescription, .{});
    pub const addIceCandidate = bridge.function(RTCPeerConnection.addIceCandidate, .{});
    pub const createDataChannel = bridge.function(RTCPeerConnection.createDataChannel, .{});
    pub const getConfiguration = bridge.function(RTCPeerConnection.getConfiguration, .{});
    pub const setConfiguration = bridge.function(RTCPeerConnection.setConfiguration, .{});
    pub const getSenders = bridge.function(RTCPeerConnection.getEmptyList, .{});
    pub const getReceivers = bridge.function(RTCPeerConnection.getEmptyList, .{});
    pub const getTransceivers = bridge.function(RTCPeerConnection.getEmptyList, .{});
    pub const restartIce = bridge.function(RTCPeerConnection.restartIce, .{ .noop = true });
    pub const close = bridge.function(RTCPeerConnection.close, .{});

    pub const localDescription = bridge.accessor(RTCPeerConnection.getLocalDescription, null, .{});
    pub const currentLocalDescription = bridge.accessor(RTCPeerConnection.getCurrentLocalDescription, null, .{});
    pub const pendingLocalDescription = bridge.accessor(RTCPeerConnection.getPendingLocalDescription, null, .{});
    pub const remoteDescription = bridge.accessor(RTCPeerConnection.getRemoteDescription, null, .{});
    pub const currentRemoteDescription = bridge.accessor(RTCPeerConnection.getCurrentRemoteDescription, null, .{});
    pub const pendingRemoteDescription = bridge.accessor(RTCPeerConnection.getPendingRemoteDescription, null, .{});
    pub const signalingState = bridge.accessor(RTCPeerConnection.getSignalingState, null, .{});
    pub const iceGatheringState = bridge.accessor(RTCPeerConnection.getIceGatheringState, null, .{});
    pub const iceConnectionState = bridge.accessor(RTCPeerConnection.getIceConnectionState, null, .{});
    pub const connectionState = bridge.accessor(RTCPeerConnection.getConnectionState, null, .{});
    pub const canTrickleIceCandidates = bridge.accessor(RTCPeerConnection.getCanTrickleIceCandidates, null, .{});
    pub const sctp = bridge.accessor(RTCPeerConnection.getSctp, null, .{});

    pub const onnegotiationneeded = EventTarget.handlerAccessor(RTCPeerConnection, "negotiationneeded");
    pub const onicecandidate = EventTarget.handlerAccessor(RTCPeerConnection, "icecandidate");
    pub const onicecandidateerror = EventTarget.handlerAccessor(RTCPeerConnection, "icecandidateerror");
    pub const onsignalingstatechange = EventTarget.handlerAccessor(RTCPeerConnection, "signalingstatechange");
    pub const oniceconnectionstatechange = EventTarget.handlerAccessor(RTCPeerConnection, "iceconnectionstatechange");
    pub const onicegatheringstatechange = EventTarget.handlerAccessor(RTCPeerConnection, "icegatheringstatechange");
    pub const onconnectionstatechange = EventTarget.handlerAccessor(RTCPeerConnection, "connectionstatechange");
    pub const ondatachannel = EventTarget.handlerAccessor(RTCPeerConnection, "datachannel");
    pub const ontrack = EventTarget.handlerAccessor(RTCPeerConnection, "track");
};

const testing = @import("../../../testing.zig");
test "WebApi: RTCPeerConnection" {
    try testing.htmlRunner("webrtc/rtc_peer_connection.html", .{});
}
