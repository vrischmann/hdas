const std = @import("std");
const fmt = std.fmt;
const heap = std.heap;
const json = std.json;
const mem = std.mem;

const Self = @This();

const logger = std.log.scoped(.health_data);

pub const MetricData = union(enum) {
    headphone_audio_exposure: struct {
        date: []const u8,
        quantity: f64,
    },
    heart_rate: struct {
        date: []const u8,
        min: f64,
        max: f64,
        avg: f64,
    },
    resting_heart_rate: struct {
        date: []const u8,
        quantity: f64,
    },
    step_count: struct {
        date: []const u8,
        quantity: f64,
    },
    walking_running_distance: struct {
        date: []const u8,
        quantity: f64,
    },
    walking_heart_rate_average: struct {
        date: []const u8,
        quantity: f64,
    },
    walking_speed: struct {
        date: []const u8,
        quantity: f64,
    },
    walking_step_length: struct {
        date: []const u8,
        quantity: f64,
    },
    weight_body_mass: struct {
        date: []const u8,
        quantity: f64,
    },
};

pub const Metric = struct {
    name: []const u8 = "",
    units: []const u8 = "",
    data: ?std.ArrayList(MetricData) = null,
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

const ParseHeadphoneAudioExposureError = error{
    InvalidMetricBody,
} || GetAsStringError || GetAsFloatError || fmt.ParseFloatError;

fn parseHeadphoneAudioExposureDataPoint(allocator: *mem.Allocator, value: json.Value) ParseHeadphoneAudioExposureError!MetricData {
    _ = allocator;
    switch (value) {
        .Object => |obj| {
            return MetricData{ .headphone_audio_exposure = .{
                .date = try getAsString(obj.get("date")),
                .quantity = try getAsFloat(obj.get("qty")),
            } };
        },
        else => return error.InvalidMetricBody,
    }
}

const ParseHeartRateError = error{
    InvalidMetricBody,
} || GetAsStringError || GetAsFloatError || fmt.ParseFloatError;

fn parseHeartRateDataPoint(allocator: *mem.Allocator, value: json.Value) ParseHeartRateError!MetricData {
    _ = allocator;
    switch (value) {
        .Object => |obj| {
            return MetricData{ .heart_rate = .{
                .date = try getAsString(obj.get("date")),
                .min = try getAsFloat(obj.get("Min")),
                .max = try getAsFloat(obj.get("Max")),
                .avg = try getAsFloat(obj.get("Avg")),
            } };
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
                    var metric_data = try std.ArrayList(MetricData).initCapacity(allocator, array.items.len);

                    for (array.items) |item| {
                        const data_point: MetricData = if (mem.eql(u8, metric.name, "headphone_audio_exposure"))
                            try parseHeadphoneAudioExposureDataPoint(allocator, item)
                        else if (mem.eql(u8, metric.name, "heart_rate"))
                            try parseHeartRateDataPoint(allocator, item)
                        else
                            return error.InvalidMetricBody;

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

    std.debug.print("health data: {s}\n", .{health_data});
}
