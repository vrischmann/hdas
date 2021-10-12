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

    // Prepare the statements

    var insert_diags = sqlite.Diagnostics{};
    var insert_metric_stmt = try context.db.prepareWithDiags(insert_metric_query, .{
        .diags = &insert_diags,
    });
    defer insert_metric_stmt.deinit();

    var insert_metric_data_point_stmt = try context.db.prepareWithDiags(insert_metric_data_point_query, .{
        .diags = &insert_diags,
    });
    defer insert_metric_data_point_stmt.deinit();

    //

    try context.db.exec("BEGIN", .{}, .{});
    errdefer {
        context.db.exec("ROLLBACK", .{}, .{}) catch unreachable;
    }

    if (body.data.metrics) |metrics| {
        for (metrics.items) |metric| {
            insert_metric_stmt.reset();
            try insert_metric_stmt.exec(.{}, .{
                .name = metric.name,
                .units = metric.units,
            });

            if (metric.data) |data| {
                logger.info("got {d} metrics for {s}, units: {s}", .{ data.items.len, metric.name, metric.units });

                for (data.items) |item| {
                    insert_metric_data_point_stmt.reset();
                    try insert_metric_data_point_stmt.exec(.{}, .{
                        .date = item.date,
                        .min = item.min,
                        .max = item.max,
                        .avg = item.avg,
                        .quantity = item.quantity,
                    });
                }
            }
        }
    }

    try context.db.exec("COMMIT", .{}, .{});

    //

    try response.writeHeader(.accepted);
    try response.writer().writeAll("Accepted");
}

const insert_metric_query =
    \\INSERT INTO metric(name, units) VALUES(?{[]const u8}, ?{[]const u8})
    \\ON CONFLICT DO NOTHING
;

const insert_metric_data_point_query =
    \\INSERT INTO metric_data_point(date, min, max, avg, quantity) VALUES(?{[]const u8}, ?, ?, ?, ?)
    \\ON CONFLICT DO NOTHING
;

const schema: []const []const u8 = &[_][]const u8{
    \\ CREATE TABLE IF NOT EXISTS metric(
    \\   id integer PRIMARY KEY,
    \\   name text NOT NULL,
    \\   units text NOT NULL,
    \\   UNIQUE (name)
    \\ );
    ,
    \\ CREATE TABLE IF NOT EXISTS metric_data_point(
    \\   id integer PRIMARY KEY,
    \\   metric_id integer NOT NULL,
    \\   date integer NOT NULL,
    \\   min real,
    \\   max real,
    \\   avg real,
    \\   quantity real,
    \\   UNIQUE (id, metric_id, date),
    \\   FOREIGN KEY (metric_id) REFERENCES metric(id)
    \\ );
};

fn getDb(allocator: *mem.Allocator, nullable_path: ?[:0]const u8) !sqlite.Db {
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
    const allocator = &gpa.allocator;

    //

    const options = try argsParser.parseForCurrentProcess(struct {
        @"listen-addr": []const u8 = "127.0.0.1",
        @"listen-port": u16 = 5804,

        @"database-path": ?[:0]const u8 = null,
    }, allocator, .print);
    defer options.deinit();

    const listen_addr = options.options.@"listen-addr";
    const listen_port = options.options.@"listen-port";

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
