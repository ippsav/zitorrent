const std = @import("std");
const assert = std.debug.assert;
const io = std.io;
const mem = std.mem;
const testing = std.testing;

/// Creates a stream which supports 'un-reading' data, so that it can be read again.
/// This makes look-ahead style parsing much easier.
/// TODO merge this with `std.io.BufferedReader`: https://github.com/ziglang/zig/issues/4501
pub fn PeekStream(
    comptime buffer_type: std.fifo.LinearFifoBufferType,
    comptime ReaderType: type,
) type {
    return struct {
        unbuffered_reader: ReaderType,
        fifo: FifoType,

        pub const Error = ReaderType.Error;
        pub const Reader = io.Reader(*Self, Error, read);

        const Self = @This();
        const FifoType = std.fifo.LinearFifo(u8, buffer_type);

        pub const init = switch (buffer_type) {
            .Static => initStatic,
            .Slice => initSlice,
            .Dynamic => initDynamic,
        };

        fn initStatic(base: ReaderType) Self {
            comptime assert(buffer_type == .Static);
            return .{
                .unbuffered_reader = base,
                .fifo = FifoType.init(),
            };
        }

        fn initSlice(base: ReaderType, buf: []u8) Self {
            comptime assert(buffer_type == .Slice);
            return .{
                .unbuffered_reader = base,
                .fifo = FifoType.init(buf),
            };
        }

        fn initDynamic(base: ReaderType, allocator: mem.Allocator) Self {
            comptime assert(buffer_type == .Dynamic);
            return .{
                .unbuffered_reader = base,
                .fifo = FifoType.init(allocator),
            };
        }

        pub fn putBackByte(self: *Self, byte: u8) !void {
            try self.putBack(&[_]u8{byte});
        }

        pub fn putBack(self: *Self, bytes: []const u8) !void {
            try self.fifo.unget(bytes);
        }

        pub fn read(self: *Self, dest: []u8) Error!usize {
            // copy over anything putBack()'d
            var dest_index = self.fifo.read(dest);
            if (dest_index == dest.len) return dest_index;

            // ask the backing stream for more
            dest_index += try self.unbuffered_reader.read(dest[dest_index..]);
            return dest_index;
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn peekStream(
    comptime lookahead: comptime_int,
    underlying_stream: anytype,
) PeekStream(.{ .Static = lookahead }, @TypeOf(underlying_stream)) {
    return PeekStream(.{ .Static = lookahead }, @TypeOf(underlying_stream)).init(underlying_stream);
}
