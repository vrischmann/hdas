const std = @import("std");
const fmt = std.fmt;
const heap = std.heap;
const json = std.json;
const mem = std.mem;
const testing = std.testing;

const Self = @This();

const logger = std.log.scoped(.health_data);

pub const MetricDataPoint = struct {
    date: []const u8,
    min: ?f64 = null,
    max: ?f64 = null,
    avg: ?f64 = null,
    quantity: ?f64 = null,
};

pub const Metric = struct {
    name: []const u8 = "",
    units: []const u8 = "",
    data: ?std.ArrayList(MetricDataPoint) = null,
};

const NullValueError = error{
    NullValue,
};

const GetAsStringError = error{
    NotAString,
} || NullValueError;

fn getAsString(nullable_value: ?json.Value) GetAsStringError![]const u8 {
    const value = nullable_value orelse return error.NullValue;
    switch (value) {
        .String => |s| return s,
        else => return error.NotAString,
    }
}

const GetAsFloatError = error{
    NotAFloat,
} || NullValueError;

fn getAsFloat(nullable_value: ?json.Value) GetAsFloatError!f64 {
    const value = nullable_value orelse return error.NullValue;
    switch (value) {
        .Float => |f| return f,
        .Integer => |n| return @intToFloat(f64, n),
        else => {
            logger.warn("value {s} is not a float", .{value});
            return error.NotAFloat;
        },
    }
}

const ParseHeartRateError = error{
    InvalidMetricBody,
} || GetAsStringError || GetAsFloatError || fmt.ParseFloatError;

fn parseHeartRateDataPoint(allocator: *mem.Allocator, value: json.Value) ParseHeartRateError!MetricDataPoint {
    _ = allocator;
    switch (value) {
        .Object => |obj| {
            return MetricDataPoint{
                .date = try getAsString(obj.get("date")),
                .min = try getAsFloat(obj.get("Min")),
                .max = try getAsFloat(obj.get("Max")),
                .avg = try getAsFloat(obj.get("Avg")),
            };
        },
        else => return error.InvalidMetricBody,
    }
}

const ParseSleepAnalysisError = error{
    NotImplemented,
} || GetAsStringError || GetAsFloatError;

fn parseSleepAnalysisDataPoint(allocator: *mem.Allocator, value: json.Value) ParseSleepAnalysisError!MetricDataPoint {
    _ = allocator;
    _ = value;
    return error.NotImplemented;
}

const ParseHeadphoneAudioExposureError = error{
    InvalidMetricBody,
} || GetAsStringError || GetAsFloatError || fmt.ParseFloatError;

fn parseGenericDataPoint(allocator: *mem.Allocator, value: json.Value) ParseHeadphoneAudioExposureError!MetricDataPoint {
    _ = allocator;
    switch (value) {
        .Object => |obj| {
            return MetricDataPoint{
                .date = try getAsString(obj.get("date")),
                .quantity = try getAsFloat(obj.get("qty")),
            };
        },
        else => return error.InvalidMetricBody,
    }
}

fn parseMetric(allocator: *mem.Allocator, value: json.Value) !Metric {
    switch (value) {
        .Object => |obj| {
            var metric = Metric{
                .name = try getAsString(obj.get("name")),
                .units = try getAsString(obj.get("units")),
            };

            const data = obj.get("data") orelse return error.InvalidBody;

            switch (data) {
                .Array => |array| {
                    var metric_data = try std.ArrayList(MetricDataPoint).initCapacity(allocator, array.items.len);

                    for (array.items) |item| {
                        // TODO(vincent): can this be made better ?

                        const data_point = if (mem.eql(u8, metric.name, "heart_rate"))
                            try parseHeartRateDataPoint(allocator, item)
                        else if (mem.eql(u8, metric.name, "sleep_analysis"))
                            try parseSleepAnalysisDataPoint(allocator, item)
                        else
                            try parseGenericDataPoint(allocator, item);

                        try metric_data.append(data_point);
                    }

                    metric.data = metric_data;
                },
                else => return error.InvalidMetricBody,
            }

            return metric;
        },
        else => return error.InvalidMetricBody,
    }
}

data: struct {
    metrics: ?std.ArrayList(Metric) = null,
} = .{},

pub fn parse(allocator: *mem.Allocator, body: []const u8) !Self {
    var parser = json.Parser.init(allocator, false);
    defer parser.deinit();

    var tree = try parser.parse(body);
    defer tree.deinit();

    //

    var res = Self{};

    const data_value = switch (tree.root) {
        .Object => |obj| obj.get("data"),
        else => return error.InvalidBody,
    } orelse return error.InvalidBody;

    const metrics_value = switch (data_value) {
        .Object => |obj| obj.get("metrics"),
        else => return error.InvalidBody,
    } orelse return error.InvalidBody;

    switch (metrics_value) {
        .Array => |array| {
            var metrics = try std.ArrayList(Metric).initCapacity(allocator, array.items.len);

            for (array.items) |item| {
                const metric = try parseMetric(allocator, item);
                try metrics.append(metric);
            }

            res.data.metrics = metrics;
        },
        else => return error.InvalidBody,
    }

    return res;
}

test "parse" {
    const build_options = @import("build_options");
    const test_data = if (build_options.test_data) |data|
        @embedFile(data)
    else
        \\{"data":{"workouts":[],"metrics":[]}}
        ;

    var arena = heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const health_data = try parse(allocator, test_data);

    if (build_options.test_data) |_| {
        try testing.expect(health_data.data.metrics != null);
        try testing.expectEqual(@as(usize, 9), health_data.data.metrics.?.items.len);

        const metrics = health_data.data.metrics.?.items;

        try testing.expectEqualStrings("headphone_audio_exposure", metrics[0].name);
        try testing.expectEqualStrings("heart_rate", metrics[1].name);
        try testing.expectEqualStrings("resting_heart_rate", metrics[2].name);
        try testing.expectEqualStrings("step_count", metrics[3].name);
        try testing.expectEqualStrings("walking_running_distance", metrics[4].name);
        try testing.expectEqualStrings("walking_heart_rate_average", metrics[5].name);
        try testing.expectEqualStrings("walking_speed", metrics[6].name);
        try testing.expectEqualStrings("walking_step_length", metrics[7].name);
        try testing.expectEqualStrings("weight_body_mass", metrics[8].name);

        for (metrics) |metric| {
            try testing.expect(metric.data != null);
            try testing.expect(metric.data.?.items.len > 0);
        }
    } else {
        try testing.expect(health_data.data.metrics != null);
        try testing.expectEqual(@as(usize, 0), health_data.data.metrics.?.items.len);
    }
}
