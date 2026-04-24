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

const Notification = @import("../Notification.zig");
const DateTime = @import("../datetime.zig").DateTime;
const milliTimestamp = @import("../datetime.zig").milliTimestamp;

const log = lp.log;
const Allocator = std.mem.Allocator;

const HAR_VERSION = "1.2";
const HTTP_VERSION = "HTTP/1.1";

// A name/value pair representing a single HTTP header.
const Header = struct {
    name: []const u8,
    value: []const u8,
};

// A single HAR entry representing one HTTP request/response pair.
const Entry = struct {
    allocator: Allocator,

    transfer_id: u32,

    // Wall-clock start time in milliseconds since Unix epoch.
    start_wall_ms: i64,

    // Monotonic start time in milliseconds (for computing elapsed time).
    start_mono_ms: u64,

    // Monotonic end time in milliseconds, set when request completes or fails.
    end_mono_ms: ?u64,

    // Whether the request failed.
    failed: bool,

    // Request fields.
    method: []const u8,
    url: []u8,
    req_headers: std.ArrayList(Header),
    req_body: ?[]const u8,

    // Response fields.
    status: ?u16,
    resp_headers: std.ArrayList(Header),
    resp_body: std.ArrayList(u8),
    mime_type: []u8,

    fn deinit(self: *Entry) void {
        self.allocator.free(self.url);
        self.allocator.free(self.mime_type);

        for (self.req_headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.req_headers.deinit();

        if (self.req_body) |b| self.allocator.free(b);

        for (self.resp_headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.resp_headers.deinit();
        self.resp_body.deinit();
    }

    // Returns the total elapsed time in milliseconds, or -1 if not yet
    // complete.
    fn elapsedMs(self: *const Entry) i64 {
        const end = self.end_mono_ms orelse return -1;
        return @intCast(end -| self.start_mono_ms);
    }

    pub fn jsonStringify(self: *const Entry, jws: anytype) !void {
        const dt = DateTime.fromUnix(self.start_wall_ms, .milliseconds) catch DateTime.now();
        const elapsed = self.elapsedMs();

        try jws.beginObject();

        try jws.objectField("startedDateTime");
        try jws.write(dt);

        try jws.objectField("time");
        try jws.write(if (elapsed >= 0) elapsed else 0);

        try jws.objectField("request");
        try writeRequest(self, jws);

        try jws.objectField("response");
        try writeResponse(self, jws);

        try jws.objectField("cache");
        try jws.beginObject();
        try jws.endObject();

        try jws.objectField("timings");
        try writeTimings(self, jws);

        try jws.endObject();
    }
};

// Recorder collects HTTP request/response data during a browser session.
// It registers for HTTP lifecycle events via the Notification system and
// accumulates entries that can later be serialised as HAR JSON.
//
// Usage:
//   var recorder = Recorder.init(allocator);
//   defer recorder.deinit();
//   try recorder.register(notification);
//   // … navigate and wait …
//   recorder.unregister(notification);
//   try recorder.dumpToWriter(writer);        // stdout
//   try recorder.dumpToFile("trace.har");     // file
pub const Recorder = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry),

    pub fn init(allocator: Allocator) Recorder {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Recorder) void {
        for (self.entries.items) |*e| {
            e.deinit();
        }
        self.entries.deinit();
    }

    // Register for all HTTP lifecycle events on the given notification instance.
    pub fn register(self: *Recorder, notification: *Notification) !void {
        try notification.register(.http_request_start, self, onHttpRequestStart);
        try notification.register(.http_response_header_done, self, onHttpResponseHeaderDone);
        try notification.register(.http_response_data, self, onHttpResponseData);
        try notification.register(.http_request_done, self, onHttpRequestDone);
        try notification.register(.http_request_fail, self, onHttpRequestFail);
    }

    // Unregister all previously registered listeners.
    pub fn unregister(self: *Recorder, notification: *Notification) void {
        notification.unregisterAll(self);
    }

    // Serialise the collected HAR data as JSON to the given writer.
    pub fn dumpToWriter(self: *const Recorder, writer: *std.Io.Writer) !void {
        try std.json.Stringify.value(HarTopLevel{ .recorder = self }, .{}, writer);
        try writer.writeByte('\n');
    }

    // Serialise the collected HAR data as JSON and write it to a file at
    // the given path, creating or truncating the file as necessary.
    pub fn dumpToFile(self: *const Recorder, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var buf: [4096]u8 = undefined;
        var file_writer_obj = file.writer(&buf);
        const writer = &file_writer_obj.interface;
        try self.dumpToWriter(writer);
        try writer.flush();
    }

    // --- internal helpers ---

    fn getEntry(self: *Recorder, id: u32) ?*Entry {
        for (self.entries.items) |*e| {
            if (e.transfer_id == id) return e;
        }
        return null;
    }

    // --- notification callbacks ---

    fn onHttpRequestStart(ctx: *anyopaque, msg: *const Notification.RequestStart) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const transfer = msg.transfer;
        const allocator = self.allocator;

        const url = try allocator.dupe(u8, transfer.url);
        errdefer allocator.free(url);

        var req_headers = std.ArrayList(Header).init(allocator);
        errdefer {
            for (req_headers.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            req_headers.deinit();
        }

        var hdr_it = transfer.req.headers.iterator();
        while (hdr_it.next()) |hdr| {
            const name = try allocator.dupe(u8, hdr.name);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, hdr.value);
            errdefer allocator.free(value);
            try req_headers.append(.{ .name = name, .value = value });
        }

        var req_body: ?[]const u8 = null;
        if (transfer.req.body) |b| {
            req_body = try allocator.dupe(u8, b);
        }
        errdefer if (req_body) |b| allocator.free(b);

        const mime_type = try allocator.dupe(u8, "");
        errdefer allocator.free(mime_type);

        const entry = Entry{
            .allocator = allocator,
            .transfer_id = transfer.id,
            .start_wall_ms = std.time.milliTimestamp(),
            .start_mono_ms = milliTimestamp(.monotonic),
            .end_mono_ms = null,
            .failed = false,
            .method = @tagName(transfer.req.method),
            .url = url,
            .req_headers = req_headers,
            .req_body = req_body,
            .status = null,
            .resp_headers = std.ArrayList(Header).init(allocator),
            .resp_body = std.ArrayList(u8).init(allocator),
            .mime_type = mime_type,
        };

        try self.entries.append(entry);
    }

    fn onHttpResponseHeaderDone(ctx: *anyopaque, msg: *const Notification.ResponseHeaderDone) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const transfer = msg.transfer;
        const entry = self.getEntry(transfer.id) orelse return;
        const allocator = self.allocator;

        if (transfer.response_header) |rh| {
            entry.status = rh.status;
        }

        var hdr_it = transfer.responseHeaderIterator();
        while (hdr_it.next()) |hdr| {
            const name = try allocator.dupe(u8, hdr.name);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, hdr.value);
            errdefer allocator.free(value);
            try entry.resp_headers.append(.{ .name = name, .value = value });
        }

        if (transfer.response_header) |*rh| {
            if (rh.contentType()) |ct| {
                allocator.free(entry.mime_type);
                entry.mime_type = try allocator.dupe(u8, ct);
            }
        }
    }

    fn onHttpResponseData(ctx: *anyopaque, msg: *const Notification.ResponseData) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const entry = self.getEntry(msg.transfer.id) orelse return;
        try entry.resp_body.appendSlice(msg.data);
    }

    fn onHttpRequestDone(ctx: *anyopaque, msg: *const Notification.RequestDone) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const entry = self.getEntry(msg.transfer.id) orelse return;
        entry.end_mono_ms = milliTimestamp(.monotonic);
    }

    fn onHttpRequestFail(ctx: *anyopaque, msg: *const Notification.RequestFail) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        _ = msg.err;
        const entry = self.getEntry(msg.transfer.id) orelse return;
        entry.end_mono_ms = milliTimestamp(.monotonic);
        entry.failed = true;
    }
};

// --- JSON helpers ---

// Top-level HAR wrapper: {"log": {...}}
const HarTopLevel = struct {
    recorder: *const Recorder,

    pub fn jsonStringify(self: HarTopLevel, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("log");
        try writeHarLog(self.recorder, jws);
        try jws.endObject();
    }
};

fn writeHarLog(recorder: *const Recorder, jws: anytype) !void {
    try jws.beginObject();

    try jws.objectField("version");
    try jws.write(HAR_VERSION);

    try jws.objectField("creator");
    try writeCreator(jws);

    try jws.objectField("pages");
    try jws.beginArray();
    try jws.endArray();

    try jws.objectField("entries");
    try jws.beginArray();
    for (recorder.entries.items) |*entry| {
        // Pass by value so the write stream sees a concrete Entry, not a
        // pointer, ensuring that Entry.jsonStringify is called correctly.
        try jws.write(entry.*);
    }
    try jws.endArray();

    try jws.endObject();
}

fn writeCreator(jws: anytype) !void {
    try jws.beginObject();
    try jws.objectField("name");
    try jws.write("lightpanda");
    try jws.objectField("version");
    try jws.write(lp.build_config.version);
    try jws.endObject();
}

fn writeRequest(entry: *const Entry, jws: anytype) !void {
    try jws.beginObject();

    try jws.objectField("method");
    try jws.write(entry.method);

    try jws.objectField("url");
    try jws.write(entry.url);

    try jws.objectField("httpVersion");
    try jws.write(HTTP_VERSION);

    try jws.objectField("cookies");
    try jws.beginArray();
    try jws.endArray();

    try jws.objectField("headers");
    try writeHeaders(entry.req_headers.items, jws);

    try jws.objectField("queryString");
    try writeQueryString(entry.url, jws);

    if (entry.req_body) |body| {
        try jws.objectField("postData");
        try jws.beginObject();
        try jws.objectField("mimeType");
        try jws.write("");
        try jws.objectField("text");
        try jws.write(body);
        try jws.endObject();
    }

    try jws.objectField("headersSize");
    try jws.write(-1);

    try jws.objectField("bodySize");
    if (entry.req_body) |b| {
        try jws.write(b.len);
    } else {
        try jws.write(-1);
    }

    try jws.endObject();
}

fn writeResponse(entry: *const Entry, jws: anytype) !void {
    try jws.beginObject();

    const status = entry.status orelse 0;
    try jws.objectField("status");
    try jws.write(status);

    try jws.objectField("statusText");
    try jws.write(statusText(status));

    try jws.objectField("httpVersion");
    try jws.write(HTTP_VERSION);

    try jws.objectField("cookies");
    try jws.beginArray();
    try jws.endArray();

    try jws.objectField("headers");
    try writeHeaders(entry.resp_headers.items, jws);

    try jws.objectField("content");
    try writeContent(entry, jws);

    try jws.objectField("redirectURL");
    try jws.write(findHeader(entry.resp_headers.items, "location") orelse "");

    try jws.objectField("headersSize");
    try jws.write(-1);

    try jws.objectField("bodySize");
    try jws.write(entry.resp_body.items.len);

    try jws.endObject();
}

fn writeContent(entry: *const Entry, jws: anytype) !void {
    try jws.beginObject();

    try jws.objectField("size");
    try jws.write(entry.resp_body.items.len);

    try jws.objectField("mimeType");
    try jws.write(entry.mime_type);

    if (entry.resp_body.items.len > 0) {
        try jws.objectField("text");
        try jws.write(entry.resp_body.items);
    }

    try jws.endObject();
}

fn writeTimings(entry: *const Entry, jws: anytype) !void {
    const elapsed = entry.elapsedMs();
    const wait = if (elapsed >= 0) elapsed else 0;
    try jws.beginObject();
    try jws.objectField("send");
    try jws.write(0);
    try jws.objectField("wait");
    try jws.write(wait);
    try jws.objectField("receive");
    try jws.write(0);
    try jws.endObject();
}

fn writeHeaders(headers: []const Header, jws: anytype) !void {
    try jws.beginArray();
    for (headers) |h| {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(h.name);
        try jws.objectField("value");
        try jws.write(h.value);
        try jws.endObject();
    }
    try jws.endArray();
}

fn writeQueryString(url: []const u8, jws: anytype) !void {
    try jws.beginArray();
    const q_start = std.mem.indexOfScalar(u8, url, '?') orelse {
        try jws.endArray();
        return;
    };
    const query = url[q_start + 1 ..];
    // Strip fragment, if any.
    const query_end = std.mem.indexOfScalar(u8, query, '#') orelse query.len;
    const query_str = query[0..query_end];

    var it = std.mem.splitScalar(u8, query_str, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const name = if (eq) |e| pair[0..e] else pair;
        const value = if (eq) |e| pair[e + 1 ..] else "";
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(name);
        try jws.objectField("value");
        try jws.write(value);
        try jws.endObject();
    }
    try jws.endArray();
}

fn findHeader(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        413 => "Payload Too Large",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "",
    };
}

