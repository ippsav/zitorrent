const std = @import("std");
const torrent = @import("torrent.zig");
const bencode = @import("bencoded.zig");
const peekStream = @import("peek_stream.zig").peekStream;

const Self = @This();

gpa: std.mem.Allocator,
torrent_metadata: torrent.TorrentMetadata,
client: std.http.Client,

pub const TrackerRequestParams = struct {
    // info_hash: the info hash of the torrent
    //  * 20 bytes long, will need to be URL encoded
    //  * Note: This is NOT the hexadecimal representation, which is 40 bytes long
    info_hash: [20]u8,
    // peer_id: a unique identifier for your client
    //  * A string of length 20 that you get to pick. You can use something like 00112233445566778899.
    peer_id: [20]u8,
    // port: the port your client is listening on
    //  * You can set this to 6881, you will not have to support this functionality during this challenge.
    port: u16,
    // uploaded: the total amount uploaded so far
    //  * Since your client hasn't uploaded anything yet, you can set this to 0.
    uploaded: usize = 0,
    // downloaded: the total amount downloaded so far
    //  * Since your client hasn't downloaded anything yet, you can set this to 0.
    downloaded: usize = 0,
    // left: the number of bytes left to download
    //  * Since you client hasn't downloaded anything yet, this'll be the total length of the file (you've extracted this value from the torrent file in previous stages)
    left: usize,
    // compact: whether the peer list should use the compact representation
    //  * The compact representation is more commonly used in the wild, the non-compact representation is mostly supported for backward-compatibility.
    compact: u8 = 1,

    pub fn new(info_hash: [20]u8, length: usize) TrackerRequestParams {
        return .{
            .info_hash = info_hash,
            .peer_id = "00112233445566778899"[0..20].*,
            .left = length,
            .port = 6881,
        };
    }

    pub fn getAsQueryParams(self: TrackerRequestParams, gpa: std.mem.Allocator) ![]const u8 {
        var query_params_array_list = std.ArrayList(u8).init(gpa);
        const writer = query_params_array_list.writer();
        defer query_params_array_list.deinit();
        try writer.print("info_hash={s}&peer_id={s}&port={d}&uploaded={d}&downloaded={d}&left={d}&compact={d}", .{ self.info_hash, self.peer_id, self.port, self.uploaded, self.downloaded, self.left, self.compact });
        const query_params = query_params_array_list.toOwnedSlice();
        return query_params;
    }
};

pub const TrackerResponse = struct {
    // An integer, indicating how often your client should make a request to the tracker.
    interval: u8,
    // A string, which contains list of peers that your client can connect to.
    // Each peer is represented using 6 bytes. The first 4 bytes are the peer's IP address and the last 2 bytes are the peer's port number.
    peers: []std.net.Address,

    pub fn parseResponseFromStream(gpa: std.mem.Allocator, reader: anytype) !TrackerResponse {
        var peek_stream = peekStream(1, reader);

        var decoded_response = try bencode.decodeFromStream(gpa, &peek_stream);
        defer decoded_response.deinit(gpa);
        std.debug.assert(decoded_response == .dictionary);

        const peers_bytes_value = decoded_response.dictionary.get("peers").?;
        std.debug.assert(peers_bytes_value == .string);

        const interval_value = decoded_response.dictionary.get("interval").?;
        std.debug.assert(interval_value == .int);
        const interval: u8 = @intCast(interval_value.int);

        var peers_array_list = std.ArrayList(std.net.Address).init(gpa);
        defer peers_array_list.deinit();
        var iterator = std.mem.window(u8, peers_bytes_value.string, 6, 6);
        while (iterator.next()) |peer_addr| {
            const port: u16 = std.mem.readInt(u16, peer_addr[4..6], .big);
            const ip = std.net.Address.initIp4(peer_addr[0..4].*, port);
            try peers_array_list.append(ip);
        }
        const peers = try peers_array_list.toOwnedSlice();

        return .{
            .peers = peers,
            .interval = interval,
        };
    }
};

pub fn new(gpa: std.mem.Allocator, metadata: torrent.TorrentMetadata) Self {
    return .{ .gpa = gpa, .torrent_metadata = metadata, .client = std.http.Client{ .allocator = gpa } };
}

pub fn getPeers(self: *Self) ![]std.net.Address {
    const hash = try self.torrent_metadata.info.getInfoHash();

    const tracker_request_params = TrackerRequestParams.new(hash, self.torrent_metadata.info.length);
    const query_params = try tracker_request_params.getAsQueryParams(self.gpa);
    defer self.gpa.free(query_params);

    var url: [200]u8 = undefined;

    var fbs = std.io.fixedBufferStream(&url);
    try fbs.writer().print("{s}?{s}", .{ self.torrent_metadata.announce, query_params });
    const uri = try std.Uri.parse(&url);

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var request = try self.client.open(.GET, uri, .{ .server_header_buffer = &server_header_buffer });

    defer request.deinit();
    try request.send(.{});
    try request.wait();
    if (request.response.status != .ok) {
        return error.TrackerServerError;
    }
    const tracker_response = try TrackerResponse.parseResponseFromStream(self.gpa, request.reader());

    return tracker_response.peers;
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
}
