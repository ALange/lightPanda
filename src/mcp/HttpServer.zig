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

// HttpServer implements the MCP HTTP+SSE transport described in the MCP spec:
//
//   GET  /sse            — client subscribes; receives a text/event-stream
//                          response.  An initial "endpoint" event tells the
//                          client which URL to POST messages to.
//   POST /message?sessionId=<id>
//                        — client sends a JSON-RPC 2.0 request; the server
//                          routes it through the MCP router and writes the
//                          response back into the SSE stream for that session.
//
// Thread model: one thread per TCP connection (matching the existing CDP
// server pattern).  An SSE connection thread keeps the SSE stream alive and
// writes periodic heartbeat comments.  POST handlers run on their own
// threads and write responses into the shared SSE stream.  All writes to a
// session's TCP stream are serialised through the McpServer.mutex that
// McpServer.sendResponse already holds.

const std = @import("std");
const lp = @import("lightpanda");
const log = lp.log;

const App = @import("../App.zig");
const router = @import("router.zig");
const McpServer = @import("Server.zig");

const Self = @This();

allocator: std.mem.Allocator,
app: *App,
sessions: std.AutoHashMap(u64, *Session),
sessions_mutex: std.Thread.Mutex,
next_id: std.atomic.Value(u64),
active_threads: std.atomic.Value(u32),
shutdown: std.atomic.Value(bool),
net_server: std.net.Server,

pub fn init(allocator: std.mem.Allocator, app: *App, address: std.net.Address) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const net_server = try address.listen(.{ .reuse_address = true });
    errdefer net_server.deinit();

    self.* = .{
        .allocator = allocator,
        .app = app,
        .sessions = std.AutoHashMap(u64, *Session).init(allocator),
        .sessions_mutex = .{},
        .next_id = .init(1),
        .active_threads = .init(0),
        .shutdown = .init(false),
        .net_server = net_server,
    };

    log.info(.mcp, "HTTP MCP server listening", .{ .address = address });
    return self;
}

pub fn deinit(self: *Self) void {
    self.shutdown.store(true, .release);
    // Closing the listener unblocks any accept() call.
    self.net_server.deinit();
    self.joinThreads();

    self.sessions_mutex.lock();
    var it = self.sessions.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.mcp_server.deinit();
        self.allocator.destroy(entry.value_ptr.*);
    }
    self.sessions.deinit();
    self.sessions_mutex.unlock();

    self.allocator.destroy(self);
}

pub fn run(self: *Self) void {
    while (true) {
        const conn = self.net_server.accept() catch |err| {
            if (self.shutdown.load(.acquire)) return;
            log.err(.mcp, "HTTP accept", .{ .err = err });
            continue;
        };

        _ = self.active_threads.fetchAdd(1, .monotonic);
        const thread = std.Thread.spawn(.{}, connectionWorker, .{ self, conn }) catch |err| {
            _ = self.active_threads.fetchSub(1, .monotonic);
            log.err(.mcp, "HTTP thread spawn", .{ .err = err });
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn joinThreads(self: *Self) void {
    while (self.active_threads.load(.monotonic) > 0) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

fn connectionWorker(self: *Self, conn: std.net.Server.Connection) void {
    defer _ = self.active_threads.fetchSub(1, .monotonic);
    defer conn.stream.close();
    self.handleConnection(conn) catch |err| {
        log.err(.mcp, "HTTP connection", .{ .err = err });
    };
}

fn handleConnection(self: *Self, conn: std.net.Server.Connection) !void {
    var req_buf: [8192]u8 = undefined;
    var conn_reader = conn.stream.reader(&req_buf);
    var write_buf: [4096]u8 = undefined;
    var conn_writer = conn.stream.writer(&write_buf);

    var http_server = std.http.Server.init(conn_reader.interface(), &conn_writer.interface);

    var req = http_server.receiveHead() catch |err| {
        log.err(.mcp, "HTTP receiveHead", .{ .err = err });
        return;
    };

    const target = req.head.target;

    // CORS preflight
    if (req.head.method == .OPTIONS) {
        try req.respond("", .{
            .status = .no_content,
            .extra_headers = &cors_headers,
        });
        return;
    }

    // GET /sse — SSE streaming endpoint
    if (req.head.method == .GET and std.mem.eql(u8, target, "/sse")) {
        try self.handleSse(conn.stream);
        return;
    }

    // POST /message?sessionId=<id>
    if (req.head.method == .POST and std.mem.startsWith(u8, target, "/message")) {
        try self.handlePost(&req);
        return;
    }

    try req.respond("Not Found", .{ .status = .not_found });
}

const cors_headers = [_]std.http.Header{
    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
    .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type" },
};

fn handleSse(self: *Self, stream: std.net.Stream) !void {
    const session_id = self.next_id.fetchAdd(1, .monotonic);

    // All SSE data for this session flows through a single buffered writer so
    // that callers only need to flush once per logical event.
    var write_buf: [4096]u8 = undefined;
    var stream_writer = stream.writer(&write_buf);

    // Write the HTTP response headers directly to the TCP stream.
    // We bypass std.http.Server's respond helpers because we need an
    // open-ended streaming response (no Content-Length).
    try stream_writer.interface.writeAll(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: keep-alive\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "\r\n",
    );
    try stream_writer.interface.flush();

    // Create an SseWriter that wraps the stream writer and formats each
    // JSON-RPC line emitted by McpServer as an SSE "data:" event.
    var sse_writer: SseWriter = .init(&stream_writer.interface);

    const mcp_svr = try McpServer.init(self.allocator, self.app, &sse_writer.interface);
    defer mcp_svr.deinit();

    // Register the session so POST handlers can look it up.
    const session = try self.allocator.create(Session);
    session.* = .{
        .id = session_id,
        .mcp_server = mcp_svr,
        .active_posts = .init(0),
    };
    {
        self.sessions_mutex.lock();
        defer self.sessions_mutex.unlock();
        try self.sessions.put(session_id, session);
    }

    // On exit: deregister the session, then wait for any in-flight POST
    // handlers to finish before returning (which would destroy the stack
    // frames for stream_writer and sse_writer that POST threads use).
    defer {
        self.sessions_mutex.lock();
        _ = self.sessions.remove(session_id);
        self.sessions_mutex.unlock();

        while (session.active_posts.load(.acquire) > 0) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        self.allocator.destroy(session);
    }

    // Send the MCP "endpoint" event so the client knows where to POST.
    var endpoint_buf: [64]u8 = undefined;
    const endpoint_data = try std.fmt.bufPrint(
        &endpoint_buf,
        "event: endpoint\ndata: /message?sessionId={d}\n\n",
        .{session_id},
    );
    try stream_writer.interface.writeAll(endpoint_data);
    try stream_writer.interface.flush();

    log.info(.mcp, "SSE session open", .{ .session_id = session_id });

    // Keep the SSE connection alive with periodic heartbeat comments.
    // The loop runs on this thread so the stack frame (and therefore
    // stream_writer) remains valid while POST threads write into it.
    // All writes to stream_writer are serialised by locking mcp_svr.mutex.
    while (!self.shutdown.load(.acquire)) {
        std.Thread.sleep(30 * std.time.ns_per_s);

        mcp_svr.mutex.lock();
        const we = stream_writer.interface.writeAll(": keepalive\n\n");
        const fe = stream_writer.interface.flush();
        mcp_svr.mutex.unlock();

        we catch break;
        fe catch break;
    }

    log.info(.mcp, "SSE session closed", .{ .session_id = session_id });
}

fn handlePost(self: *Self, req: *std.http.Server.Request) !void {
    // Parse the sessionId from the URL query string: /message?sessionId=<id>
    const session_id = parseSessionId(req.head.target) orelse {
        try req.respond("Bad Request: missing or invalid sessionId", .{ .status = .bad_request });
        return;
    };

    // Look up the session and atomically increment active_posts while still
    // holding sessions_mutex so the session cannot be destroyed while we
    // hold a reference to it.
    const session = blk: {
        self.sessions_mutex.lock();
        defer self.sessions_mutex.unlock();
        const s = self.sessions.get(session_id) orelse break :blk null;
        _ = s.active_posts.fetchAdd(1, .monotonic);
        break :blk s;
    } orelse {
        try req.respond("Session not found", .{ .status = .not_found });
        return;
    };
    defer _ = session.active_posts.fetchSub(1, .release);

    // Read the JSON-RPC request body.
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var body_reader = req.reader();
    const body_bytes = try body_reader.interface.readAlloc(aa, 64 * 1024);
    const body = std.mem.trim(u8, body_bytes, " \r\n\t");

    if (body.len == 0) {
        try req.respond("Bad Request: empty body", .{ .status = .bad_request });
        return;
    }

    // Route through the MCP router.  The response is written to the SSE
    // stream via mcp_server → sse_writer → stream_writer → TCP.
    router.handleMessage(session.mcp_server, aa, body) catch |err| {
        log.err(.mcp, "handleMessage error", .{ .err = err });
        try req.respond("Internal Server Error", .{ .status = .internal_server_error });
        return;
    };

    // The response was sent over the SSE stream; acknowledge the POST.
    const ack_headers = [_]std.http.Header{
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    };
    try req.respond("", .{ .status = .accepted, .extra_headers = &ack_headers });
}

fn parseSessionId(target: []const u8) ?u64 {
    const q = std.mem.indexOf(u8, target, "?") orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |param| {
        const key = "sessionId=";
        if (std.mem.startsWith(u8, param, key)) {
            return std.fmt.parseInt(u64, param[key.len..], 10) catch null;
        }
    }
    return null;
}

// Per-SSE-connection state shared between the SSE thread and POST threads.
const Session = struct {
    id: u64,
    mcp_server: *McpServer,
    // Reference count of in-flight POST handlers currently using mcp_server.
    // The SSE thread waits for this to reach 0 before returning (and
    // invalidating the stack-allocated stream_writer that POST threads use).
    active_posts: std.atomic.Value(u32),
};

// SseWriter wraps an underlying std.io.Writer and reformats each JSON-RPC
// line written by McpServer.sendResponse() into an SSE "data:" event.
//
// McpServer calls:
//   writer.writeAll("{...json...}\n")  — one JSON-RPC message per call
//   writer.flush()                     — signals end of message
//
// SseWriter produces on the wire:
//   "data: {…json…}\n\n"
//
// Both writeAll and flush pass through the single drain() vtable entry.
// A drain call with a zero-byte payload is treated as a flush and forwarded
// to the inner writer unchanged.
const SseWriter = struct {
    inner: *std.io.Writer,
    interface: std.io.Writer,

    pub fn init(inner: *std.io.Writer) SseWriter {
        return .{
            .inner = inner,
            .interface = .{
                .vtable = &vtable,
                .buffer = &.{},
            },
        };
    }

    const vtable = std.Io.Writer.VTable{
        .drain = drain,
    };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SseWriter = @alignCast(@fieldParentPtr("interface", w));

        // Sum up the total number of payload bytes.
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |s| total += s.len;
        if (data.len > 0) total += data[data.len - 1].len * splat;

        if (total == 0) {
            // Zero-byte drain == flush; forward to inner writer.
            self.inner.flush() catch return error.WriteFailed;
            return 0;
        }

        // Emit the SSE "data: " prefix.
        self.inner.writeAll("data: ") catch return error.WriteFailed;

        // Write the solid (non-repeated) slices.
        for (data[0 .. data.len - 1]) |s| {
            self.inner.writeAll(s) catch return error.WriteFailed;
        }

        // Write the final slice splat times.
        if (data.len > 0) {
            const pattern = data[data.len - 1];
            for (0..splat) |_| {
                self.inner.writeAll(pattern) catch return error.WriteFailed;
            }
        }

        // McpServer already appends '\n' to every message; add one more '\n'
        // to produce the SSE double-newline message terminator.
        self.inner.writeAll("\n") catch return error.WriteFailed;

        // Flush immediately so the client receives the event without waiting
        // for the next write or a kernel buffer flush.
        self.inner.flush() catch return error.WriteFailed;

        return total;
    }
};
