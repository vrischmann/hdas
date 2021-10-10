const std = @import("std");
const builtin = @import("builtin");
const heap = std.heap;
const json = std.json;
const mem = std.mem;
const time = std.time;

const argsParser = @import("args");
const http = @import("apple_pie");
const sqlite = @import("sqlite");

const HealthData = @import("HealthData.zig");

pub const log_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .info,
    .ReleaseFast => .info,
    .ReleaseSmall => .info,
};

const logger = std.log.scoped(.main);

const Context = struct {
    root_allocator: *mem.Allocator,
    db: *sqlite.Db,
};

fn handler(context: *Context, response: *http.Response, request: http.Request) !void {
    const startHandling = time.milliTimestamp();
    defer {
        logger.info("handled request in {d}ms", .{time.milliTimestamp() - startHandling});
    }

    var arena = heap.ArenaAllocator.init(context.root_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    // Always close the connection
    response.close = true;

    // Validate

    if (request.context.method != .post) {
        try response.writeHeader(.bad_request);
        try response.writer().writeAll("Bad Request");
        return;
    }

    // Parse the body

    const body = try HealthData.parse(allocator, request.body());
    _ = body;

    if (body.data.metrics) |metrics| {
        for (metrics.items) |metric| {
            if (metric.data) |data| {
                logger.info("got {d} metrics for {s}, units: {s}", .{ data.items.len, metric.name, metric.units });
                for (data.items) |item| {
                    switch (item) {
                        .heart_rate => |v| {
                            logger.info("got heart rate, min: {d}, max: {d}, avg: {d}", .{ v.min, v.max, v.avg });
                        },
                        else => {},
                    }
                }
            }
        }
    }

    //

    try response.writeHeader(.accepted);
    try response.writer().writeAll("Accepted");
}

fn getDb(allocator: *mem.Allocator, path: []const u8) !sqlite.Db {
    const tmp_path = try allocator.dupeZ(u8, path);
    defer allocator.free(tmp_path);

    return try sqlite.Db.init(.{
        .mode = if (path.len == 0) .{ .Memory = {} } else .{ .File = tmp_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
    });
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.debug.panic("leak detected", .{});
    };
    const allocator = &gpa.allocator;

    //

    const options = try argsParser.parseForCurrentProcess(struct {
        @"listen-addr": []const u8 = "127.0.0.1",
        @"listen-port": u16 = 5804,

        @"database-path": []const u8 = "",
    }, allocator, .print);
    defer options.deinit();

    const listen_addr = options.options.@"listen-addr";
    const listen_port = options.options.@"listen-port";

    //

    var db = try getDb(allocator, options.options.@"database-path");
    defer db.deinit();

    //

    var context: Context = .{
        .root_allocator = allocator,
        .db = &db,
    };

    logger.info("listening on {s}:{d}\n", .{ listen_addr, listen_port });

    try http.listenAndServe(
        allocator,
        try std.net.Address.parseIp(listen_addr, listen_port),
        &context,
        handler,
    );
}
