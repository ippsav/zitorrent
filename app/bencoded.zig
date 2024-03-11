const std = @import("std");

const ParseResult = struct { value: Value, new_cursor: usize };

pub const Value = union(enum) {
    string: []const u8,
    int: i64,

    fn parseValue(bytes: []const u8, cursor: usize) !ParseResult {
        if (bytes[cursor] == 'i') {
            return parseAssignedInt(bytes, cursor);
        } else if (std.mem.indexOfScalar(u8, bytes, ':')) |i| {
            return parseString(bytes, cursor, i);
        }
        return error.InvalidToken;
    }

    fn parseString(bytes: []const u8, cursor: usize, delimiter_index: usize) ParseResult {
        const string_len = std.fmt.parseInt(usize, bytes[cursor..delimiter_index], 10) catch {
            fatal("Error parsing string length", .{});
        };

        return .{ .value = Value{ .string = bytes[delimiter_index + 1 .. delimiter_index + string_len + 1] }, .new_cursor = delimiter_index + string_len + 1 };
    }

    fn parseAssignedInt(bytes: []const u8, cursor: usize) ParseResult {
        const number_length = std.mem.indexOfScalar(u8, bytes[cursor..], 'e') orelse {
            fatal("Error parsing integer, missing end (e)", .{});
        };
        const parsedNumber = std.fmt.parseInt(i64, bytes[cursor + 1 .. number_length], 10) catch {
            fatal("Error parsing integer: {s}", .{bytes[cursor + 1 .. number_length]});
        };
        return .{ .value = Value{ .int = parsedNumber }, .new_cursor = cursor + number_length + 1 };
    }

    pub fn toJsonValue(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        switch (self) {
            .string => |v| {
                var string = std.ArrayList(u8).init(allocator);
                defer string.deinit();
                try std.json.stringify(v, .{}, string.writer());
                return string.toOwnedSlice();
            },
            .int => |n| {
                var string = std.ArrayList(u8).init(allocator);
                defer string.deinit();
                try std.json.stringify(n, .{}, string.writer());
                return string.toOwnedSlice();
            },
        }
    }
};

pub const Scanner = struct {
    gpa: std.mem.Allocator,

    input: []const u8 = "",
    cursor: usize = 0,

    pub fn initWithCompleteInput(allocator: std.mem.Allocator, complete_input: []const u8) Scanner {
        return Scanner{
            .input = complete_input,
            .gpa = allocator,
        };
    }

    pub fn next(self: *Scanner) ?Value {
        if (self.cursor == self.input.len) {
            return null;
        }
        const parse_result = Value.parseValue(self.input, self.cursor) catch {
            fatal("error parsing at {d}\n", .{self.cursor});
        };
        self.cursor = parse_result.new_cursor;
        return parse_result.value;
    }
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}
