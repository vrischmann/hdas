const std = @import("std");
const builtin = @import("builtin");
const heap = std.heap;
const json = std.json;
const mem = std.mem;
const fmt = std.fmt;
const time = std.time;

const argsParser = @import("args");
const http = @import("apple_pie");
const prometheus = @import("prometheus");
const sqlite = @import("sqlite");

const HealthData = @import("HealthData.zig");
const RegistryType = @import("main.zig").RegistryType;

const logger = std.log.scoped(.handlers);

pub const Context = struct {
    root_allocator: mem.Allocator,

    db: *sqlite.Db,
    registry: *RegistryType,

    debug: struct {
        dump_request: bool = false,
    } = .{},
};

pub fn handleMetrics(context: *Context, response: *http.Response, _: http.Request, _: ?*const anyopaque) !void {
    var arena = heap.ArenaAllocator.init(context.root_allocator);
    defer arena.deinit();

    try context.registry.write(arena.allocator(), response.writer());
}

pub fn handleHealthData(context: *Context, response: *http.Response, request: http.Request, _: ?*const anyopaque) !void {
    const startHandling = time.milliTimestamp();
    defer {
        logger.info("handled request in {d}ms", .{time.milliTimestamp() - startHandling});
    }

    var arena = heap.ArenaAllocator.init(context.root_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Always close the connection
    response.close = true;

    // Validate
    if (request.context.method != .post) {
        try response.writeHeader(.bad_request);
        try response.writer().writeAll("Bad Request");
        return;
    }

    // Parse the body

    const raw_body = request.body();

    if (context.debug.dump_request) {
        var buf: [128]u8 = undefined;
        const path = try fmt.bufPrint(&buf, "health_data_{d}.json", .{time.milliTimestamp()});

        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(raw_body);
    }

    var body = HealthData.parse(allocator, raw_body) catch |err| switch (err) {
        error.UnexpectedEndOfJson => {
            logger.warn("invalid json {s}", .{fmt.fmtSliceEscapeLower(raw_body)});
            return;
        },
        else => {
            logger.err("unable to parse body {s}, err: {s}", .{
                fmt.fmtSliceEscapeLower(raw_body),
                err,
            });
            return err;
        },
    };
    defer body.deinit();

    // Prepare the statements

    var diags = sqlite.Diagnostics{};
    var stmts = Statements.prepare(context.db, &diags) catch |err| {
        logger.err("unable to prepare statements, err: {s}, diagnostics: {s}", .{ err, diags });
        return err;
    };
    defer stmts.deinit();

    //

    var global_savepoint = try context.db.savepoint("global");
    defer global_savepoint.rollback();

    if (body.data.metrics) |metrics| {
        for (metrics.items) |metric| {
            stmts.insert_metric.reset();

            var metric_savepoint = try context.db.savepoint("metric");
            defer metric_savepoint.rollback();

            const metric_id = (try stmts.insert_metric.one(i64, .{}, .{
                .name = metric.name,
                .units = metric.units,
            })) orelse {
                logger.info("unable to insert or fetch metric", .{});
                continue;
            };

            if (metric.data) |data| {
                logger.info("got {d} metrics for {s}, units: {s}", .{ data.items.len, metric.name, metric.units });

                for (data.items) |item| {
                    stmts.insert_data_point_generic.reset();
                    stmts.insert_data_point_heart_rate.reset();
                    stmts.insert_data_point_sleep_analysis_query.reset();

                    switch (item) {
                        .generic => |dp| {
                            try stmts.insert_data_point_generic.exec(.{}, .{
                                .metric_id = metric_id,
                                .date = dp.date,
                                .quantity = dp.quantity,
                            });
                        },
                        .heart_rate => |dp| {
                            try stmts.insert_data_point_heart_rate.exec(.{}, .{
                                .metric_id = metric_id,
                                .date = dp.date,
                                .min = dp.min,
                                .max = dp.max,
                                .avg = dp.avg,
                            });
                        },
                        .sleep_analysis => |dp| {
                            try stmts.insert_data_point_sleep_analysis_query.exec(.{}, .{
                                .metric_id = metric_id,
                                .date = dp.date,
                                .sleep_start = dp.sleep_start,
                                .sleep_end = dp.sleep_end,
                                .sleep_source = dp.sleep_source,
                                .in_bed_start = dp.in_bed_start,
                                .in_bed_end = dp.in_bed_end,
                                .in_bed_source = dp.in_bed_source,
                                .in_bed = dp.in_bed,
                                .asleep = dp.asleep,
                            });
                        },
                    }
                }
            }

            // Reset all statements before committing
            stmts.insert_metric.reset();
            stmts.insert_data_point_generic.reset();
            stmts.insert_data_point_heart_rate.reset();
            stmts.insert_data_point_sleep_analysis_query.reset();

            metric_savepoint.commit();
        }
    }

    global_savepoint.commit();

    //

    try response.writeHeader(.accepted);
    try response.writer().writeAll("Accepted");
}

const Statements = struct {
    const insert_metric_query =
        \\INSERT INTO metric(name, units) VALUES(?{[]const u8}, ?{[]const u8})
        \\ON CONFLICT DO UPDATE SET units = excluded.units
        \\RETURNING id
    ;
    const insert_data_point_generic_query =
        \\INSERT INTO data_point_generic(
        \\  metric_id, date, quantity
        \\)
        \\VALUES(
        \\  ?{i64}, strftime('%s', ?{[]const u8}), ?{f64}
        \\)
        \\ON CONFLICT DO NOTHING
    ;
    const insert_data_point_heart_rate_query =
        \\INSERT INTO data_point_heart_rate(
        \\  metric_id, date, min, max, avg
        \\)
        \\VALUES(
        \\  ?{i64}, strftime('%s', ?{[]const u8}), ?{f64}, ?{f64}, ?{f64}
        \\)
        \\ON CONFLICT DO NOTHING
    ;
    const insert_data_point_sleep_analysis_query =
        \\INSERT INTO data_point_sleep_analysis(
        \\  metric_id, date,
        \\  sleep_start, sleep_end, sleep_source,
        \\  in_bed_start, in_bed_end, in_bed_source,
        \\  in_bed, asleep
        \\)
        \\VALUES(
        \\  ?{i64}, strftime('%s', ?{[]const u8}),
        \\  strftime('%s', ?{[]const u8}), strftime('%s', ?{[]const u8}), ?{[]const u8},
        \\  strftime('%s', ?{[]const u8}), strftime('%s', ?{[]const u8}), ?{[]const u8},
        \\  ?{f64}, ?{f64}
        \\)
        \\ON CONFLICT DO NOTHING
    ;

    insert_metric: sqlite.StatementType(.{}, insert_metric_query),
    insert_data_point_generic: sqlite.StatementType(.{}, insert_data_point_generic_query),
    insert_data_point_heart_rate: sqlite.StatementType(.{}, insert_data_point_heart_rate_query),
    insert_data_point_sleep_analysis_query: sqlite.StatementType(.{}, insert_data_point_sleep_analysis_query),

    fn prepare(db: *sqlite.Db, diags: *sqlite.Diagnostics) !Statements {
        var res: Statements = undefined;

        res.insert_metric = try db.prepareWithDiags(insert_metric_query, .{
            .diags = diags,
        });
        res.insert_data_point_generic = try db.prepareWithDiags(insert_data_point_generic_query, .{
            .diags = diags,
        });
        res.insert_data_point_heart_rate = try db.prepareWithDiags(insert_data_point_heart_rate_query, .{
            .diags = diags,
        });
        res.insert_data_point_sleep_analysis_query = try db.prepareWithDiags(insert_data_point_sleep_analysis_query, .{
            .diags = diags,
        });

        return res;
    }

    pub fn deinit(self: *Statements) void {
        self.insert_metric.deinit();
        self.insert_data_point_generic.deinit();
        self.insert_data_point_heart_rate.deinit();
        self.insert_data_point_sleep_analysis_query.deinit();
    }
};
