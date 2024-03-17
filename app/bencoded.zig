const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    list: []Value,
    dictionary: std.StringArrayHashMap(Value),

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .dictionary => {
                const dictionary_iterator = self.dictionary.iterator();
                for (0..dictionary_iterator.len) |i| {
                    dictionary_iterator.values[i].deinit(allocator);
                    allocator.free(dictionary_iterator.keys[i]);
                }
                self.*.dictionary.deinit();
            },
            .list => {
                for (self.list) |*value| {
                    value.deinit(allocator);
                }
                allocator.free(self.list);
            },
            .string => {
                allocator.free(self.string);
            },
            else => {},
        }
    }

    fn parseValueFromStream(gpa: std.mem.Allocator, peek_stream: anytype) !Value {
        var reader = peek_stream.reader();
        const first_byte = try reader.readByte();
        switch (first_byte) {
            '0'...'9' => {
                try peek_stream.putBackByte(first_byte);
                return parseStringFromStream(gpa, peek_stream);
            },
            'i' => {
                return parseAssignedIntFromStream(gpa, peek_stream);
            },
            'l' => {
                return parseListFromStream(gpa, peek_stream);
            },
            'd' => {
                return parseDictionaryFromStream(gpa, peek_stream);
            },
            else => return error.InvalidToken,
        }
    }

    fn parseStringFromStream(gpa: std.mem.Allocator, peek_stream: anytype) Value {
        var reader = peek_stream.reader();
        var bytes_till_delimiter: []const u8 = reader.readUntilDelimiterAlloc(gpa, ':', 4096) catch {
            fatal("Out of memory, exiting...", .{});
        };

        const string_len = std.fmt.parseInt(usize, bytes_till_delimiter, 10) catch {
            fatal("Error parsing string length\n", .{});
        };

        gpa.free(bytes_till_delimiter);

        var string = gpa.alloc(u8, string_len) catch {
            fatal("Out of memory, exiting...\n", .{});
        };

        _ = reader.read(string) catch {
            fatal("Error reading from memory, exiting...\n", .{});
        };

        return .{ .string = string };
    }

    fn parseAssignedIntFromStream(gpa: std.mem.Allocator, peek_stream: anytype) Value {
        var buffer = std.ArrayList(u8).init(gpa);
        defer buffer.deinit();
        var reader = peek_stream.reader();

        while (true) {
            const byte = reader.readByte() catch {
                fatal("End of stream, exiting...", .{});
            };
            if (byte == 'e') {
                break;
            }
            buffer.append(byte) catch {
                fatal("Out of memory, exiting...", .{});
            };
        }
        const number = std.fmt.parseInt(i64, buffer.items, 10) catch |err| {
            fatal("Error parsing number, got: {s}\n{any}", .{ buffer.items, err });
        };

        return .{ .int = number };
    }

    fn parseListFromStream(gpa: std.mem.Allocator, peek_stream: anytype) Value {
        var values_list = std.ArrayList(Value).init(gpa);
        defer values_list.deinit();
        var reader = peek_stream.reader();

        while (true) {
            const byte = reader.readByte() catch {
                fatal("End of stream, exiting...", .{});
            };
            if (byte == 'e') {
                break;
            }
            peek_stream.putBackByte(byte) catch {
                fatal("Out of memory, exiting...", .{});
            };

            const value = parseValueFromStream(gpa, peek_stream) catch |err| {
                fatal("Error parsing value, {any}", .{err});
            };
            values_list.append(value) catch {
                fatal("Out of memory, exiting...", .{});
            };
        }
        var values_slice = values_list.toOwnedSlice() catch {
            fatal("Out of memory, exiting...", .{});
        };
        return .{ .list = values_slice };
    }

    fn parseDictionaryFromStream(gpa: std.mem.Allocator, peek_stream: anytype) Value {
        var reader = peek_stream.reader();
        var values_map = std.StringArrayHashMap(Value).init(gpa);

        while (true) {
            const byte = reader.readByte() catch {
                fatal("End of stream, exiting...\n", .{});
            };

            if (byte == 'e') {
                break;
            }

            peek_stream.putBackByte(byte) catch {
                fatal("Out of memory, exiting...\n", .{});
            };

            var key = Value.parseStringFromStream(gpa, peek_stream);
            const value = Value.parseValueFromStream(gpa, peek_stream) catch {
                fatal("Error parsing value\n", .{});
            };

            values_map.put(key.string, value) catch {
                fatal("Out of memory, exiting...\n", .{});
            };
        }

        const SortCtx = struct {
            map: std.StringArrayHashMap(Value),

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return std.mem.order(u8, ctx.map.keys()[a_index], ctx.map.keys()[b_index]).compare(std.math.CompareOperator.lt);
            }
        };

        const sort_ctx = SortCtx{ .map = values_map };

        values_map.sort(sort_ctx);

        return .{ .dictionary = values_map };
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

pub fn decodeFromStream(gpa: std.mem.Allocator, peek_stream: anytype) !Value {
    return try Value.parseValueFromStream(gpa, peek_stream);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn compareValues(lhs: Value, rhs: Value) !void {
    const activeTag = std.meta.activeTag;
    std.debug.assert(activeTag(lhs) == activeTag(rhs));

    switch (lhs) {
        .string => |v| {
            try std.testing.expectEqualStrings(v, rhs.string);
        },
        .int => |v| {
            try std.testing.expectEqual(v, rhs.int);
        },
        .list => |l| {
            for (l, rhs.list) |v1, v2| {
                try compareValues(v1, v2);
            }
        },
        .dictionary => |d| {
            var lhs_iterator = d.iterator();
            var rhs_iterator = rhs.dictionary.iterator();
            for (0..lhs_iterator.len, 0..rhs_iterator.len) |i, j| {
                try std.testing.expectEqualStrings(lhs_iterator.keys[i], rhs_iterator.keys[j]);
                try compareValues(lhs_iterator.values[i], rhs_iterator.values[j]);
            }
        },
    }
}

test "parse string value from stream" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    defer {
        std.debug.assert(gpa.deinit() == .ok);
    }
    var fbs = std.io.fixedBufferStream("5:hello");
    var peek_stream = std.io.peekStream(1, fbs.reader());

    var value = Value.parseStringFromStream(allocator, &peek_stream);

    defer value.deinit(allocator);

    try compareValues(value, .{ .string = "hello" });
}

test "parse int value from stream" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    defer {
        std.debug.assert(gpa.deinit() == .ok);
    }
    var fbs = std.io.fixedBufferStream("i52e");
    var peek_stream = std.io.peekStream(1, fbs.reader());

    _ = try peek_stream.reader().readByte();

    var value = Value.parseAssignedIntFromStream(allocator, &peek_stream);

    defer value.deinit(allocator);
    errdefer value.deinit(allocator);

    try compareValues(value, .{ .int = 52 });
}

test "parse list of values from stream" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    defer {
        std.debug.assert(gpa.deinit() == .ok);
    }

    var fbs = std.io.fixedBufferStream("l5:helloi32ee");
    var peek_stream = std.io.peekStream(1, fbs.reader());

    _ = try peek_stream.reader().readByte();

    var value_list = Value.parseListFromStream(allocator, &peek_stream);

    var expected_list_values: [2]Value = .{ .{ .string = "hello" }, .{ .int = 32 } };

    var expected_list: Value = .{ .list = &expected_list_values };

    defer value_list.deinit(allocator);

    try compareValues(value_list, expected_list);
}

test "parse dictionary of values from stream" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    defer {
        std.debug.assert(gpa.deinit() == .ok);
    }

    // foo : bar , hello : 52 , bar : [ "hello" , 53 ]
    var fbs = std.io.fixedBufferStream("d3:foo3:bar5:helloi52e3:barl5:helloi53eee");
    var peek_stream = std.io.peekStream(1, fbs.reader());

    _ = try peek_stream.reader().readByte();

    var list_values: [2]Value = .{ .{ .string = "hello" }, .{ .int = 53 } };

    var values: [3]Value = .{ .{ .list = &list_values }, .{ .string = "bar" }, .{ .int = 52 } };
    var keys: [3][]const u8 = .{ "bar", "foo", "hello" };

    var expected_hash_map: std.StringArrayHashMap(Value) = std.StringArrayHashMap(Value).init(allocator);
    defer expected_hash_map.deinit();

    for (0..keys.len) |i| {
        try expected_hash_map.put(keys[i], values[i]);
    }

    var expected_dictionary_value: Value = .{ .dictionary = expected_hash_map };

    var dictionary_value = Value.parseDictionaryFromStream(allocator, &peek_stream);
    defer dictionary_value.deinit(allocator);

    try compareValues(dictionary_value, expected_dictionary_value);
}
