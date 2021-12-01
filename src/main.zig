const std = @import("std");
const builtin = @import("builtin");
const fmt = std.fmt;
const heap = std.heap;
const json = std.json;
const mem = std.mem;
const net = std.net;
const time = std.time;

const argsParser = @import("args");
const http = @import("apple_pie");
const prometheus = @import("prometheus");
const sqlite = @import("sqlite");

const HealthData = @import("HealthData.zig");
const Exporter = @import("Exporter.zig");
const Handlers = @import("Handlers.zig");

pub const log_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .info,
    .ReleaseFast => .info,
    .ReleaseSmall => .info,
};

const logger = std.log.scoped(.main);

pub const RegistryType = prometheus.Registry(.{});

const schema: []const []const u8 = &[_][]const u8{
    \\ CREATE TABLE IF NOT EXISTS metric(
    \\   id integer PRIMARY KEY,
    \\   name text NOT NULL,
    \\   units text NOT NULL,
    \\   UNIQUE (name)
    \\ );
    ,
    \\ CREATE TABLE IF NOT EXISTS data_point_generic(
    \\   id integer PRIMARY KEY,
    \\   metric_id integer NOT NULL,
    \\   date integer NOT NULL,
    \\   quantity real,
    \\   exported integer NOT NULL DEFAULT 0,
    \\   UNIQUE (id, metric_id, date),
    \\   FOREIGN KEY (metric_id) REFERENCES metric(id)
    \\ );
    ,
    \\ CREATE TABLE IF NOT EXISTS data_point_heart_rate(
    \\   id integer PRIMARY KEY,
    \\   metric_id integer NOT NULL,
    \\   date integer NOT NULL,
    \\   min real,
    \\   max real,
    \\   avg real,
    \\   exported integer NOT NULL DEFAULT 0,
    \\   UNIQUE (id, metric_id, date),
    \\   FOREIGN KEY (metric_id) REFERENCES metric(id)
    \\ );
    ,
    \\ CREATE TABLE IF NOT EXISTS data_point_sleep_analysis(
    \\   id integer PRIMARY KEY,
    \\   metric_id integer NOT NULL,
    \\   date integer NOT NULL,
    \\   sleep_start integer NOT NULL,
    \\   sleep_end integer NOT NULL,
    \\   sleep_source text NOT NULL,
    \\   in_bed_start integer NOT NULL,
    \\   in_bed_end integer NOT NULL,
    \\   in_bed_source text NOT NULL,
    \\   in_bed real NOT NULL,
    \\   asleep real NOT NULL,
    \\   exported integer NOT NULL DEFAULT 0,
    \\   UNIQUE (id, metric_id, date),
    \\   FOREIGN KEY (metric_id) REFERENCES metric(id)
    \\ );
};

fn getDb(allocator: mem.Allocator, nullable_path: ?[:0]const u8) !sqlite.Db {
    _ = allocator;

    const db_mode = if (nullable_path) |path|
        sqlite.Db.Mode{ .File = path }
    else
        sqlite.Db.Mode{ .Memory = {} };

    var diags = sqlite.Diagnostics{};
    return sqlite.Db.init(.{
        .mode = db_mode,
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .diags = &diags,
    }) catch |err| {
        logger.err("unable to open database, err: {s}, diagnostics: {s}", .{ err, diags });
        return err;
    };
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.debug.panic("leak detected", .{});
    };
    const allocator = gpa.allocator();

    //

    const options = try argsParser.parseForCurrentProcess(struct {
        @"listen-addr": []const u8 = "127.0.0.1",
        @"listen-port": u16 = 5804,

        @"victoria-addr": []const u8 = "127.0.0.1",
        @"victoria-port": u16 = 4242,

        @"database-path": ?[:0]const u8 = null,

        @"debug-dump-request": bool = false,
    }, allocator, .print);
    defer options.deinit();

    //

    var db = try getDb(allocator, options.options.@"database-path");
    defer db.deinit();

    _ = try db.pragma(void, .{}, "foreign_keys", "1");

    inline for (schema) |ddl| {
        var diags = sqlite.Diagnostics{};
        db.exec(ddl, .{ .diags = &diags }, .{}) catch |err| {
            logger.err("unable to executing statement, err: {s}, message: {s}", .{ err, diags });
            return err;
        };
    }

    // Initialize and start the Victoria exporter

    var exporter = try Exporter.init(
        allocator,
        &db,
        try net.Address.parseIp(options.options.@"victoria-addr", options.options.@"victoria-port"),
    );
    defer exporter.deinit();

    var exporter_thread = try std.Thread.spawn(.{}, Exporter.run, .{&exporter});
    defer exporter_thread.join();

    // Initialize the Prometheus registry

    var registry = try RegistryType.create(allocator);
    defer registry.destroy();

    //

    var context: Handlers.Context = .{
        .root_allocator = allocator,
        .db = &db,
        .registry = registry,
        .debug = .{
            .dump_request = options.options.@"debug-dump-request",
        },
    };

    logger.info("listening on {s}:{d}", .{ options.options.@"listen-addr", options.options.@"listen-port" });
    if (context.debug.dump_request) {
        logger.info("dumping all request bodies in current directory", .{});
    }

    try http.listenAndServe(
        allocator,
        try net.Address.parseIp(options.options.@"listen-addr", options.options.@"listen-port"),
        &context,
        comptime http.router.Router(*Handlers.Context, &.{
            http.router.post("/health_data", Handlers.handleHealthData),
            http.router.get("/metrics", Handlers.handleMetrics),
        }),
    );
}
