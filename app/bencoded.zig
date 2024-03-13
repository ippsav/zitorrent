const std = @import("std");

const ParseResult = struct { value: Value, new_cursor: usize };

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    list: []Value,

    fn parseValue(gpa: std.mem.Allocator, bytes: []const u8, cursor: usize) !ParseResult {
        switch (bytes[cursor]) {
            '0'...'9' => {
                return parseString(bytes, cursor);
            },
            'i' => return parseAssignedInt(bytes, cursor),
            'l' => return parseList(gpa, bytes, cursor),
            else => return error.InvalidToken,
        }
    }

    fn parseList(allocator: std.mem.Allocator, bytes: []const u8, cursor: usize) ParseResult {
        var index = cursor + 1;
        var values_list = std.ArrayList(Value).init(allocator);
        defer values_list.deinit();
        while (bytes[index] != 'e' and index != bytes.len - 1) {
            const parse_result = Value.parseValue(allocator, bytes, index) catch {
                fatal("Error parsing list", .{});
            };
            values_list.append(parse_result.value) catch {
                fatal("Out of memory, exiting...", .{});
            };
            index = parse_result.new_cursor;
        }
        const list = values_list.toOwnedSlice() catch {
            fatal("Boom", .{});
        };
        return .{ .value = .{ .list = list }, .new_cursor = index };
    }

    fn parseString(bytes: []const u8, cursor: usize) ParseResult {
        var delimiter_index: usize = undefined;
        if (std.mem.indexOfScalar(u8, bytes[cursor..], ':')) |v| {
            delimiter_index = v + cursor;
        } else {
            fatal("Error parsing string missing delimiter ':'", .{});
        }
        const string_len = std.fmt.parseInt(usize, bytes[cursor..delimiter_index], 10) catch {
            fatal("Error parsing string length", .{});
        };

        return .{ .value = Value{ .string = bytes[delimiter_index + 1 .. delimiter_index + string_len + 1] }, .new_cursor = delimiter_index + string_len + 1 };
    }

    fn parseAssignedInt(bytes: []const u8, cursor: usize) ParseResult {
        const number_length = blk: {
            const e_tag_index = std.mem.indexOfScalar(u8, bytes[cursor..], 'e') orelse {
                break :blk fatal("Error parsing integer, missing end (e)", .{});
            };
            break :blk e_tag_index - 1;
        };
        const parsedNumber = std.fmt.parseInt(i64, bytes[cursor + 1 .. cursor + 1 + number_length], 10) catch {
            fatal("Error parsing integer: {s}", .{bytes[cursor + 1 .. cursor + 1 + number_length]});
        };
        return .{ .value = Value{ .int = parsedNumber }, .new_cursor = cursor + number_length + 2 };
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
            .list => |l| {
                var string = std.ArrayList(u8).init(allocator);
                defer string.deinit();
                var writer = string.writer();
                _ = try writer.write("[");
                for (l, 0..) |v, i| {
                    const json_value = try v.toJsonValue(allocator);
                    _ = try writer.write(json_value);
                    allocator.free(json_value);
                    if (i != l.len - 1) try writer.writeByte(',');
                }
                _ = try writer.write("]");
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
        if (self.cursor >= self.input.len - 1) {
            return null;
        }
        const parse_result = Value.parseValue(self.gpa, self.input, self.cursor) catch {
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
