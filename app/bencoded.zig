const std = @import("std");

pub const KVPair = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    list: []Value,
    dictionary: std.StringArrayHashMap(Value),

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .dictionary => {
                for (self.dictionary.values()) |*map_value| {
                    switch (map_value.*) {
                        .list => {
                            allocator.free(map_value.list);
                        },
                        .dictionary => {
                            map_value.deinit(allocator);
                        },
                        else => {},
                    }
                }
                self.*.dictionary.deinit();
            },
            .list => {
                allocator.free(self.list);
            },
            else => {},
        }
    }

    fn parseValue(gpa: std.mem.Allocator, cursor: *usize, bytes: []const u8) !Value {
        switch (bytes[cursor.*]) {
            '0'...'9' => {
                return parseString(cursor, bytes);
            },
            'i' => return parseAssignedInt(cursor, bytes),
            'l' => return parseList(gpa, cursor, bytes),
            'd' => return parseDictionary(gpa, cursor, bytes),
            else => return error.InvalidToken,
        }
    }

    fn parseDictionary(allocator: std.mem.Allocator, cursor: *usize, bytes: []const u8) Value {
        var arena = std.heap.ArenaAllocator.init(allocator);
        var arena_allocator = arena.allocator();
        defer arena.deinit();

        var index = cursor.* + 1;
        var values_map = std.StringArrayHashMap(Value).init(allocator);

        var key_value_pair_array = std.ArrayList(KVPair).init(arena_allocator);

        while (bytes[index] != 'e') {
            const key = Value.parseString(&index, bytes);

            const value = Value.parseValue(allocator, &index, bytes) catch {
                fatal("Error parsing list {c} in {s}\n", .{ bytes[index], bytes[index..] });
            };

            key_value_pair_array.append(.{ .key = key.string, .value = value }) catch {
                fatal("Out of memory, exiting ...", .{});
            };
        }
        // var key_value_pair_slice = key_value_pair_array.toOwnedSlice() catch {
        //     fatal("Out of memory, exiting ...", .{});
        // };

        std.sort.insertion(KVPair, key_value_pair_array.items, {}, compareKeys);

        for (key_value_pair_array.items) |entry| {
            values_map.put(entry.key, entry.value) catch {
                fatal("Out of memory, exiting ...", .{});
            };
        }

        cursor.* = index + 1;
        return .{ .dictionary = values_map };
    }

    fn parseList(allocator: std.mem.Allocator, cursor: *usize, bytes: []const u8) Value {
        var index = cursor.* + 1;
        var values_list = std.ArrayList(Value).init(allocator);
        defer values_list.deinit();
        while (bytes[index] != 'e') {
            const value = Value.parseValue(allocator, &index, bytes) catch {
                fatal("Error parsing list {c} in {s}\n", .{ bytes[index], bytes[index..] });
            };
            values_list.append(value) catch {
                fatal("Out of memory, exiting...", .{});
            };
        }
        const list = values_list.toOwnedSlice() catch {
            fatal("Boom", .{});
        };
        cursor.* = index + 1;
        return .{ .list = list };
    }

    fn parseString(cursor: *usize, bytes: []const u8) Value {
        var delimiter_index: usize = undefined;
        if (std.mem.indexOfScalar(u8, bytes[cursor.*..], ':')) |v| {
            delimiter_index = v + cursor.*;
        } else {
            fatal("Error parsing string missing delimiter ':'", .{});
        }
        const string_len = std.fmt.parseInt(usize, bytes[cursor.*..delimiter_index], 10) catch {
            fatal("Error parsing string length", .{});
        };
        cursor.* = delimiter_index + string_len + 1;
        return .{ .string = bytes[delimiter_index + 1 .. delimiter_index + string_len + 1] };
    }

    fn parseAssignedInt(cursor: *usize, bytes: []const u8) Value {
        const number_length = blk: {
            const e_tag_index = std.mem.indexOfScalar(u8, bytes[cursor.*..], 'e') orelse {
                break :blk fatal("Error parsing integer, missing end (e)", .{});
            };
            break :blk e_tag_index - 1;
        };
        const parsedNumber = std.fmt.parseInt(i64, bytes[cursor.* + 1 .. cursor.* + 1 + number_length], 10) catch {
            fatal("Error parsing integer: {s}", .{bytes[cursor.* + 1 .. cursor.* + 1 + number_length]});
        };
        cursor.* = cursor.* + number_length + 2;
        return .{ .int = parsedNumber };
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
                    try std.json.stringify(k.key_ptr.*, .{}, writer);
                    _ = try writer.writeByte(':');
                    try k.value_ptr.*.toJsonValue(writer);
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

// pub const Scanner = struct {
//     gpa: std.mem.Allocator,
//
//     input: []const u8 = "",
//     cursor: usize = 0,
//
//     pub fn initWithCompleteInput(allocator: std.mem.Allocator, complete_input: []const u8) Scanner {
//         return Scanner{
//             .input = complete_input,
//             .gpa = allocator,
//         };
//     }
//
//     pub fn next(self: *Scanner) ?Value {
//         if (self.cursor >= self.input.len - 1) {
//             return null;
//         }
//         var parse_result = Value.parseValue(self.gpa, self.input, self.cursor) catch {
//             fatal("error parsing at {d}\n", .{self.cursor});
//         };
//         self.cursor = parse_result.new_cursor;
//         return parse_result.value;
//     }
// };

pub fn decode(allocator: std.mem.Allocator, cursor: *usize, bytes: []const u8) !Value {
    return try Value.parseValue(allocator, cursor, bytes);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn compareKeys(_: void, lhs: KVPair, rhs: KVPair) bool {
    return std.mem.order(u8, lhs.key, rhs.key).compare(std.math.CompareOperator.lt);
}
