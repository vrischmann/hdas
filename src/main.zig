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

const Statements = struct {
    const insert_metric_query =
        \\INSERT INTO metric(name, units) VALUES(?{[]const u8}, ?{[]const u8})
        \\ON CONFLICT DO NOTHING
    ;
    const insert_generic_data_point_query =
        \\INSERT INTO metric_data_point(metric_id, type, date, quantity) VALUES(?{i64}, ?{usize}, ?{[]const u8}, ?{f64})
        \\ON CONFLICT DO NOTHING
    ;
    const insert_heart_rate_data_point_query =
        \\INSERT INTO metric_data_point(metric_id, type, date, min, max, avg) VALUES(?{i64}, ?{usize}, ?{[]const u8}, ?{f64}, ?{f64}, ?{f64})
        \\ON CONFLICT DO NOTHING
    ;

    insert_metric: sqlite.StatementType(.{}, insert_metric_query),
    insert_generic_data_point: sqlite.StatementType(.{}, insert_generic_data_point_query),
    insert_heart_rate_data_point: sqlite.StatementType(.{}, insert_heart_rate_data_point_query),

    fn prepare(db: *sqlite.Db, diags: *sqlite.Diagnostics) !Statements {
        var res: Statements = undefined;

        res.insert_metric = try db.prepareWithDiags(insert_metric_query, .{
            .diags = diags,
        });
        res.insert_generic_data_point = try db.prepareWithDiags(insert_generic_data_point_query, .{
            .diags = diags,
        });
        res.insert_heart_rate_data_point = try db.prepareWithDiags(insert_heart_rate_data_point_query, .{
            .diags = diags,
        });

        return res;
    }

    pub fn deinit(self: *Statements) void {
        self.insert_metric.deinit();
        self.insert_generic_data_point.deinit();
    }
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

    var diags = sqlite.Diagnostics{};
    var stmts = Statements.prepare(context.db, &diags) catch |err| {
        logger.err("unable to prepare statements, err: {s}, diagnostics: {s}", .{ err, diags });
        return err;
    };
    defer stmts.deinit();

    //

    try context.db.exec("BEGIN", .{}, .{});
    errdefer {
        context.db.exec("ROLLBACK", .{}, .{}) catch unreachable;
    }

    if (body.data.metrics) |metrics| {
        for (metrics.items) |metric| {
            stmts.insert_metric.reset();
            try stmts.insert_metric.exec(.{}, .{
                .name = metric.name,
                .units = metric.units,
            });
            const metric_id = context.db.getLastInsertRowID();

            if (metric.data) |data| {
                logger.info("got {d} metrics for {s}, units: {s}", .{ data.items.len, metric.name, metric.units });

                for (data.items) |item| {
                    stmts.insert_generic_data_point.reset();

                    switch (item) {
                        .generic => |dp| {
                            try stmts.insert_generic_data_point.exec(.{}, .{
                                .metric_id = metric_id,
                                .@"type" = @intCast(usize, @enumToInt(HealthData.MetricDataPoint.generic)),
                                .date = dp.date,
                                .quantity = dp.quantity,
                            });
                        },
                        .heart_rate => |dp| {
                            try stmts.insert_heart_rate_data_point.exec(.{}, .{
                                .metric_id = metric_id,
                                .@"type" = @intCast(usize, @enumToInt(HealthData.MetricDataPoint.heart_rate)),
                                .date = dp.date,
                                .min = dp.min,
                                .max = dp.max,
                                .avg = dp.avg,
                            });
                        },
                        .sleep_analysis => |dp| {
                            _ = dp;
                        },
                    }
                }
            }
        }
    }

    try context.db.exec("COMMIT", .{}, .{});

    //

    try response.writeHeader(.accepted);
    try response.writer().writeAll("Accepted");
}

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
    \\   type integer NOT NULL,
    \\   date integer NOT NULL,
    \\   min real,
    \\   max real,
    \\   avg real,
    \\   quantity real,
    \\   UNIQUE (id, metric_id, type, date),
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
