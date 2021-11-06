const std = @import("std");
const builtin = @import("builtin");
const fmt = std.fmt;
const heap = std.heap;
const json = std.json;
const mem = std.mem;
const net = std.net;
const time = std.time;

const prometheus = @import("prometheus");
const sqlite = @import("sqlite");

const HealthData = @import("HealthData.zig");

const logger = std.log.scoped(.exporter);

const Self = @This();

allocator: *mem.Allocator,
db: *sqlite.Db,
addr: net.Address,

stream: ?net.Stream = null,

pub fn init(allocator: *mem.Allocator, db: *sqlite.Db, addr: net.Address) !Self {
    var res = Self{
        .allocator = allocator,
        .db = db,
        .addr = addr,
    };
    return res;
}

pub fn deinit(self: *Self) void {
    if (self.stream) |stream| {
        stream.close();
    }
}

pub fn run(self: *Self) !void {
    while (true) {
        try self.doExport();
        time.sleep(10 * time.ns_per_s);
    }
}

fn doExport(self: *Self) !void {
    const start = time.milliTimestamp();
    defer {
        logger.info("exported data in {d}ms", .{time.milliTimestamp() - start});
    }
    logger.debug("exporting data", .{});

    // Try to connect to Victoria
    self.stream = net.tcpConnectToAddress(self.addr) catch |err| {
        logger.err("unable to connect to victoria at {s}, err: {s}", .{ self.addr, err });
        return;
    };

    // Prepare the statements

    var diags = sqlite.Diagnostics{};
    var stmts = Statements.prepare(self.db, &diags) catch |err| {
        logger.err("unable to prepare statements, err: {s}, diagnostics: {s}", .{ err, diags });
        return err;
    };
    defer stmts.deinit();

    // Export

    // Assume the stream is present, otherwise we wouldn't be called;
    var stream = self.stream.?;
    var writer = stream.writer();

    try self.exportHeartRate(writer, &stmts);
    try self.exportGeneric(writer, &stmts, .weight_body_mass);
    try self.exportGeneric(writer, &stmts, .walking_heart_rate_average);
    try self.exportGeneric(writer, &stmts, .resting_heart_rate);
    try self.exportGeneric(writer, &stmts, .walking_running_distance);
    try self.exportGeneric(writer, &stmts, .walking_speed);
    try self.exportSleepAnalysis(writer, &stmts);
}

// TODO(vincent): merge both functions ? they're quite similar.

fn exportHeartRate(self: *Self, writer: net.Stream.Writer, stmts: *Statements) !void {
    // Store the data point ids to mark as exported next.
    var ids = try std.ArrayList(usize).initCapacity(self.allocator, 64);
    defer ids.deinit();

    // Export all data points
    stmts.get_heart_rate_data_point.reset();
    var iter = try stmts.get_heart_rate_data_point.iterator(
        struct {
            id: usize,
            value: f64,
            date: usize,
        },
        .{},
    );

    while (try iter.next(.{})) |row| {
        try writer.print("put health_data_heart_rate {d} {d} \n", .{
            row.date,
            row.value,
        });
        try ids.append(row.id);
    }
    logger.debug("exported {d} heart_rate data points", .{ids.items.len});

    // Mark the data point as exported

    var global_savepoint = try self.db.savepoint("global");
    defer global_savepoint.rollback();

    for (ids.items) |id| {
        stmts.mark_heart_rate_as_exported.reset();
        try stmts.mark_heart_rate_as_exported.exec(.{}, .{
            .id = id,
        });
    }

    global_savepoint.commit();
}

fn exportGeneric(self: *Self, writer: net.Stream.Writer, stmts: *Statements, comptime metric_name: @Type(.EnumLiteral)) !void {
    // Store the data point ids to mark as exported next.
    var ids = try std.ArrayList(usize).initCapacity(self.allocator, 64);
    defer ids.deinit();

    // Export all data point
    stmts.get_generic_data_point.reset();
    var iter = try stmts.get_generic_data_point.iterator(
        struct {
            id: usize,
            value: f64,
            date: usize,
        },
        .{
            .name = @as([]const u8, @tagName(metric_name)),
        },
    );

    while (try iter.next(.{})) |row| {
        try writer.print("put health_data_" ++ @tagName(metric_name) ++ " {d} {d} \n", .{
            row.date,
            row.value,
        });
        try ids.append(row.id);
    }
    logger.debug("exported {d} " ++ @tagName(metric_name) ++ " data point", .{ids.items.len});

    // Mark the data point as exported

    var global_savepoint = try self.db.savepoint("global");
    defer global_savepoint.rollback();

    for (ids.items) |id| {
        stmts.mark_generic_as_exported.reset();
        try stmts.mark_generic_as_exported.exec(.{}, .{
            .id = id,
        });
    }

    global_savepoint.commit();
}

fn exportSleepAnalysis(self: *Self, writer: net.Stream.Writer, stmts: *Statements) !void {
    // Store the data point ids to mark as exported next.
    var ids = try std.ArrayList(usize).initCapacity(self.allocator, 64);
    defer ids.deinit();

    // Export all data point
    stmts.get_sleep_analysis_data_point.reset();
    var iter = try stmts.get_sleep_analysis_data_point.iterator(
        struct {
            id: usize,
            in_bed: f64,
            asleep: f64,
            date: usize,
        },
        .{},
    );

    while (try iter.next(.{})) |row| {
        try writer.print("put health_data_sleep_analysis {d} {d} type=in_bed\n", .{
            row.date,
            row.in_bed,
        });
        try writer.print("put health_data_sleep_analysis {d} {d} type=asleep\n", .{
            row.date,
            row.asleep,
        });
        try ids.append(row.id);
    }
    logger.debug("exported {d} sleep_analysis data points", .{ids.items.len});

    // Mark the data point as exported

    var global_savepoint = try self.db.savepoint("global");
    defer global_savepoint.rollback();

    for (ids.items) |id| {
        stmts.mark_sleep_analysis_as_exported.reset();
        try stmts.mark_sleep_analysis_as_exported.exec(.{}, .{
            .id = id,
        });
    }

    global_savepoint.commit();
}

const Statements = struct {
    const get_heart_rate_data_point_query =
        \\SELECT d.id, d.max, d.date
        \\FROM data_point_heart_rate d
        \\INNER JOIN metric m ON d.metric_id = m.id
        \\WHERE m.name = 'heart_rate'
        \\AND d.exported = 0
    ;

    const get_sleep_analysis_data_point_query =
        \\SELECT d.id, d.in_bed, d.asleep, d.date
        \\FROM data_point_sleep_analysis d
        \\INNER JOIN metric m ON d.metric_id = m.id
        \\WHERE m.name = 'sleep_analysis'
        \\AND d.exported = 0
    ;

    const get_generic_data_point_query =
        \\SELECT d.id, d.quantity, d.date
        \\FROM data_point_generic d
        \\INNER JOIN metric m ON d.metric_id = m.id
        \\WHERE m.name = ?{[]const u8}
        \\AND d.exported = 0
    ;

    const mark_heart_rate_as_exported_query =
        \\UPDATE data_point_heart_rate
        \\SET exported = 1
        \\WHERE id = ?{usize}
    ;
    const mark_sleep_analysis_as_exported_query =
        \\UPDATE data_point_sleep_analysis
        \\SET exported = 1
        \\WHERE id = ?{usize}
    ;
    const mark_generic_as_exported_query =
        \\UPDATE data_point_generic
        \\SET exported = 1
        \\WHERE id = ?{usize}
    ;

    get_heart_rate_data_point: sqlite.StatementType(.{}, get_heart_rate_data_point_query),
    get_sleep_analysis_data_point: sqlite.StatementType(.{}, get_sleep_analysis_data_point_query),
    get_generic_data_point: sqlite.StatementType(.{}, get_generic_data_point_query),
    mark_heart_rate_as_exported: sqlite.StatementType(.{}, mark_heart_rate_as_exported_query),
    mark_sleep_analysis_as_exported: sqlite.StatementType(.{}, mark_sleep_analysis_as_exported_query),
    mark_generic_as_exported: sqlite.StatementType(.{}, mark_generic_as_exported_query),

    fn prepare(db: *sqlite.Db, diags: *sqlite.Diagnostics) !Statements {
        var res: Statements = undefined;

        res.get_heart_rate_data_point = try db.prepareWithDiags(get_heart_rate_data_point_query, .{
            .diags = diags,
        });
        res.get_sleep_analysis_data_point = try db.prepareWithDiags(get_sleep_analysis_data_point_query, .{
            .diags = diags,
        });
        res.get_generic_data_point = try db.prepareWithDiags(get_generic_data_point_query, .{
            .diags = diags,
        });
        res.mark_heart_rate_as_exported = try db.prepareWithDiags(mark_heart_rate_as_exported_query, .{
            .diags = diags,
        });
        res.mark_sleep_analysis_as_exported = try db.prepareWithDiags(mark_sleep_analysis_as_exported_query, .{
            .diags = diags,
        });
        res.mark_generic_as_exported = try db.prepareWithDiags(mark_generic_as_exported_query, .{
            .diags = diags,
        });

        return res;
    }

    fn deinit(self: *Statements) void {
        self.get_heart_rate_data_point.deinit();
        self.get_generic_data_point.deinit();
        self.mark_heart_rate_as_exported.deinit();
        self.mark_generic_as_exported.deinit();
    }
};
