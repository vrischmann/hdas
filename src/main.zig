const std = @import("std");
const heap = std.heap;
const json = std.json;
const mem = std.mem;

const argsParser = @import("args");
const http = @import("apple_pie");

const HealthData = @import("HealthData.zig");

pub const io_mode = .evented;

const Context = struct {
    root_allocator: *mem.Allocator,
};

const logger = std.log.scoped(.main);

fn handler(context: *Context, response: *http.Response, request: http.Request) !void {
    var arena = heap.ArenaAllocator.init(context.root_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    // Validate

    if (request.context.method != .post) {
        try response.writeHeader(.bad_request);
        try response.writer().writeAll("Bad Request");
        return;
    }

    // Parse the body

    const body = try HealthData.parse(allocator, request.body());
    _ = body;

    //

    try response.writeHeader(.accepted);
    try response.writer().writeAll("Accepted");
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
    }, allocator, .print);
    defer options.deinit();

    const listen_addr = options.options.@"listen-addr";
    const listen_port = options.options.@"listen-port";

    logger.info("listening on {s}:{d}\n", .{ listen_addr, listen_port });

    //

    var context: Context = .{
        .root_allocator = allocator,
    };

    try http.listenAndServe(
        allocator,
        try std.net.Address.parseIp(listen_addr, listen_port),
        &context,
        handler,
    );
}
