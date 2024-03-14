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
                try stdout.print("{}\n", .{v});
            }
        },
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn fatalHelp() noreturn {
    fatal("Usage: your_bittorent.zig <command> <args>", .{});
}
