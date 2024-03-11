const std = @import("std");
const stdout = std.io.getStdOut().writer();
const Scanner = @import("./bencoded.zig").Scanner;
const allocator = std.heap.page_allocator;

const Command = enum {
    decode,
};

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3) {
        fatalHelp();
    }

    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        fatalHelp();
    };

    switch (command) {
        .decode => {
            var bencoded_scanner = Scanner.initWithCompleteInput(allocator, args[2]);
            while (bencoded_scanner.next()) |v| {
                const json_value = try v.toJsonValue(allocator);
                defer allocator.free(json_value);
                std.debug.print("{s}\n", .{json_value});
            }
        },
    }
}

fn decodeBencode(encodedValue: []const u8) !*const []const u8 {
    if (encodedValue[0] >= '0' and encodedValue[0] <= '9') {
        const firstColon = std.mem.indexOf(u8, encodedValue, ":");
        if (firstColon == null) {
            return error.InvalidArgument;
        }
        return &encodedValue[firstColon.? + 1 ..];
    } else {
        try stdout.print("Only strings are supported at the moment\n", .{});
        std.os.exit(1);
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn fatalHelp() noreturn {
    fatal("Usage: your_bittorent.zig <command> <args>", .{});
}
