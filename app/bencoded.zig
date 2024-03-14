const std = @import("std");

const ParseResult = struct { value: Value, new_cursor: usize };

pub const KVPair = struct {
    key: Value,
    value: Value,
};

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    list: []Value,
    dictionary: std.StringArrayHashMap(KVPair),

    fn parseValue(gpa: std.mem.Allocator, bytes: []const u8, cursor: usize) !ParseResult {
        switch (bytes[cursor]) {
            '0'...'9' => {
                return parseString(bytes, cursor);
            },
            'i' => return parseAssignedInt(bytes, cursor),
            'l' => return parseList(gpa, bytes, cursor),
            'd' => return parseDictionary(gpa, bytes, cursor),
            else => return error.InvalidToken,
        }
    }

    fn parseDictionary(allocator: std.mem.Allocator, bytes: []const u8, cursor: usize) ParseResult {
        var index = cursor + 1;
        var values_map = std.StringArrayHashMap(KVPair).init(allocator);

        var key_value_pairs = std.ArrayList(KVPair).init(allocator);

        while (bytes[index] != 'e') {
            const key_result = Value.parseString(bytes, index);
            index = key_result.new_cursor;

            const value_result = Value.parseValue(allocator, bytes, index) catch {
                fatal("Error parsing list {c} in {s}\n", .{ bytes[index], bytes[index..] });
            };
            index = value_result.new_cursor;
            key_value_pairs.append(.{ .key = key_result.value, .value = value_result.value }) catch {
                fatal("Out of memory, exiting ...", .{});
            };
        }

        var key_value_pairs_slice = key_value_pairs.toOwnedSlice() catch {
            fatal("Out of memory, exiting ...", .{});
        };
        defer allocator.free(key_value_pairs_slice);
        key_value_pairs.deinit();

        std.sort.insertion(KVPair, key_value_pairs_slice, {}, compareKVPair);
        for (key_value_pairs_slice) |entry| {
            values_map.put(entry.key.string, entry) catch {
                fatal("Out of memory, exiting ...", .{});
            };
        }

        return .{ .value = .{ .dictionary = values_map }, .new_cursor = index + 1 };
    }

    fn parseList(allocator: std.mem.Allocator, bytes: []const u8, cursor: usize) ParseResult {
        var index = cursor + 1;
        var values_list = std.ArrayList(Value).init(allocator);
        defer values_list.deinit();
        while (bytes[index] != 'e') {
            const parse_result = Value.parseValue(allocator, bytes, index) catch {
                fatal("Error parsing list {c} in {s}\n", .{ bytes[index], bytes[index..] });
            };
            values_list.append(parse_result.value) catch {
                fatal("Out of memory, exiting...", .{});
            };
            index = parse_result.new_cursor;
        }
        const list = values_list.toOwnedSlice() catch {
            fatal("Boom", .{});
        };
        return .{ .value = .{ .list = list }, .new_cursor = index + 1 };
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

    pub fn toJsonValue(self: Value, writer: anytype) !void {
        switch (self) {
            .string => |v| {
                try std.json.stringify(v, .{}, writer);
            },
            .int => |n| {
                try std.json.stringify(n, .{}, writer);
            },
            .list => |l| {
                try writer.writeByte('[');
                for (l, 0..) |v, i| {
                    try v.toJsonValue(writer);
                    if (i != l.len - 1) try writer.writeByte(',');
                }
                _ = try writer.writeByte(']');
            },
            .dictionary => |map| {
                _ = try writer.writeByte('{');
                var i: usize = 0;
                var map_iterator = map.iterator();
                while (map_iterator.next()) |k| {
                    try k.value_ptr.*.key.toJsonValue(writer);
                    _ = try writer.writeByte(':');
                    try k.value_ptr.*.value.toJsonValue(writer);
                    i += 1;
                    if (i < map.count()) try writer.writeByte(',');
                }
                _ = try writer.writeByte('}');
            },
        }
    }
    pub fn format(self: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try self.toJsonValue(writer);
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

fn compareKVPair(_: void, lhs: KVPair, rhs: KVPair) bool {
    return compareStrings({}, lhs.key.string, rhs.key.string);
}

fn compareStrings(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs).compare(std.math.CompareOperator.lt);
}
