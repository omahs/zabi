const abi_ens = @import("abi.zig");
const block = @import("../../types/block.zig");
const clients = @import("../../root.zig");
const decoder = @import("../../decoding/decoder.zig");
const ens_utils = @import("ens_utils.zig");
const std = @import("std");
const testing = std.testing;
const types = @import("../../types/ethereum.zig");
const utils = @import("../../utils/utils.zig");

const Address = types.Address;
const Allocator = std.mem.Allocator;
const BlockNumberRequest = block.BlockNumberRequest;
const Clients = clients.clients.wallet.WalletClients;
const EnsContracts = @import("contracts.zig").EnsContracts;
const Hex = types.Hex;
const InitOptsHttp = PubClient.InitOptions;
const InitOptsWs = WebSocketClient.InitOptions;
const PubClient = clients.clients.PubClient;
const RPCResponse = types.RPCResponse;
const WebSocketClient = clients.clients.WebSocket;

/// A public client that interacts with the ENS contracts.
///
/// Currently ENSAvatar is not supported but will be in future versions.
pub fn ENSClient(comptime client_type: Clients) type {
    return struct {
        const ENS = @This();

        /// The underlaying rpc client type (ws or http)
        const ClientType = switch (client_type) {
            .http => PubClient,
            .websocket => WebSocketClient,
        };

        /// The inital settings depending on the client type.
        const InitOpts = switch (client_type) {
            .http => InitOptsHttp,
            .websocket => InitOptsWs,
        };

        /// This is the same allocator as the rpc_client.
        /// Its a field mostly for convinience
        allocator: Allocator,
        /// The http or ws client that will be use to query the rpc server
        rpc_client: *ClientType,
        /// ENS contracts to be used by this client.
        ens_contracts: EnsContracts,

        /// Starts the RPC connection
        /// If the contracts are null it defaults to mainnet contracts.
        pub fn init(self: *ENS, opts: InitOpts, ens_contracts: ?EnsContracts) !void {
            const ens_client = try opts.allocator.create(ClientType);
            errdefer opts.allocator.destroy(ens_client);

            if (opts.chain_id) |id| {
                switch (id) {
                    .ethereum, .sepolia => {},
                    else => return error.InvalidChain,
                }
            }

            try ens_client.init(opts);

            self.* = .{
                .rpc_client = ens_client,
                .allocator = opts.allocator,
                .ens_contracts = ens_contracts orelse .{},
            };
        }
        /// Frees and destroys any allocated memory
        pub fn deinit(self: *ENS) void {
            self.rpc_client.deinit();
            self.allocator.destroy(self.rpc_client);

            self.* = undefined;
        }
        /// Gets the ENS address associated with the ENS name.
        ///
        /// Caller owns the memory if the request is successfull.
        /// Calls the resolver address and decodes with address resolver.
        ///
        /// The names are not normalized so make sure that the names are normalized before hand.
        pub fn getEnsAddress(self: *ENS, name: []const u8, opts: BlockNumberRequest) !RPCResponse(Address) {
            const hash = try ens_utils.hashName(name);

            const encoded = try abi_ens.addr_resolver.encode(self.allocator, .{hash});
            defer self.allocator.free(encoded);

            var buffer: [1024]u8 = undefined;
            const bytes_read = ens_utils.convertEnsToBytes(buffer[0..], name);

            const resolver_encoded = try abi_ens.resolver.encode(self.allocator, .{ buffer[0..bytes_read], encoded });
            defer self.allocator.free(resolver_encoded);

            const value = try self.rpc_client.sendEthCall(.{ .london = .{
                .to = self.ens_contracts.ensUniversalResolver,
                .data = resolver_encoded,
            } }, opts);
            errdefer value.deinit();

            if (value.response.len == 0)
                return error.EvmFailedToExecute;

            const decoded = try decoder.decodeAbiParameters(self.allocator, abi_ens.resolver.outputs, value.response, .{ .allow_junk_data = true });

            if (decoded[0].len == 0)
                return error.FailedToDecodeResponse;

            const decoded_result = try decoder.decodeAbiParameters(self.allocator, abi_ens.addr_resolver.outputs, decoded[0], .{ .allow_junk_data = true });

            if (decoded_result[0].len == 0)
                return error.FailedToDecodeResponse;

            return RPCResponse(Address).fromJson(value.arena, decoded_result[0]);
        }
        /// Gets the ENS name associated with the address.
        ///
        /// Caller owns the memory if the request is successfull.
        /// Calls the reverse resolver and decodes with the same.
        ///
        /// This will fail if its not a valid checksumed address.
        pub fn getEnsName(self: *ENS, address: []const u8, opts: BlockNumberRequest) !RPCResponse([]const u8) {
            if (!utils.isAddress(address))
                return error.InvalidAddress;

            var address_reverse: [53]u8 = undefined;
            var buf: [40]u8 = undefined;
            _ = std.ascii.lowerString(&buf, address[2..]);

            @memcpy(address_reverse[0..40], buf[0..40]);
            @memcpy(address_reverse[40..], ".addr.reverse");

            var buffer: [100]u8 = undefined;
            const bytes_read = ens_utils.convertEnsToBytes(buffer[0..], address_reverse[0..]);

            const encoded = try abi_ens.reverse_resolver.encode(self.allocator, .{buffer[0..bytes_read]});
            defer self.allocator.free(encoded);

            const value = try self.rpc_client.sendEthCall(.{ .london = .{
                .to = self.ens_contracts.ensUniversalResolver,
                .data = encoded,
            } }, opts);
            errdefer value.deinit();

            const address_bytes = try utils.addressToBytes(address);

            if (value.response.len == 0)
                return error.EvmFailedToExecute;

            const decoded = try decoder.decodeAbiParameters(self.allocator, abi_ens.reverse_resolver.outputs, value.response, .{});

            if (!std.mem.eql(u8, &address_bytes, &decoded[1]))
                return error.InvalidAddress;

            return RPCResponse([]const u8).fromJson(value.arena, decoded[0]);
        }
        /// Gets the ENS resolver associated with the name.
        ///
        /// Caller owns the memory if the request is successfull.
        /// Calls the find resolver and decodes with the same one.
        ///
        /// The names are not normalized so make sure that the names are normalized before hand.
        pub fn getEnsResolver(self: *ENS, name: []const u8, opts: BlockNumberRequest) !Address {
            var buffer: [1024]u8 = undefined;
            const bytes_read = ens_utils.convertEnsToBytes(buffer[0..], name);

            const encoded = try abi_ens.find_resolver.encode(self.allocator, .{buffer[0..bytes_read]});
            defer self.allocator.free(encoded);

            const value = try self.rpc_client.sendEthCall(.{ .london = .{
                .to = self.ens_contracts.ensUniversalResolver,
                .data = encoded,
            } }, opts);
            defer value.deinit();

            const decoded = try decoder.decodeAbiParameters(self.allocator, abi_ens.find_resolver.outputs, value.response, .{ .allow_junk_data = true });

            var address: Address = undefined;
            @memcpy(address[0..], decoded[0][0..]);

            return address;
        }
        /// Gets a text record for a specific ENS name.
        ///
        /// Caller owns the memory if the request is successfull.
        /// Calls the resolver and decodes with the text resolver.
        ///
        /// The names are not normalized so make sure that the names are normalized before hand.
        pub fn getEnsText(self: *ENS, name: []const u8, key: []const u8, opts: BlockNumberRequest) !RPCResponse([]const u8) {
            var buffer: [1024]u8 = undefined;
            const bytes_read = ens_utils.convertEnsToBytes(buffer[0..], name);

            const hash = try ens_utils.hashName(name);
            const text_encoded = try abi_ens.text_resolver.encode(self.allocator, .{ hash, key });
            defer self.allocator.free(text_encoded);

            const encoded = try abi_ens.resolver.encode(self.allocator, .{ buffer[0..bytes_read], text_encoded });
            defer self.allocator.free(encoded);

            const value = try self.rpc_client.sendEthCall(.{ .london = .{
                .to = self.ens_contracts.ensUniversalResolver,
                .data = encoded,
            } }, opts);
            errdefer value.deinit();

            if (value.response.len == 0)
                return error.EvmFailedToExecute;

            const decoded = try decoder.decodeAbiParameters(self.allocator, abi_ens.resolver.outputs, value.response, .{});
            const decoded_text = try decoder.decodeAbiParameters(self.allocator, abi_ens.text_resolver.outputs, decoded[0], .{});

            if (decoded_text[0].len == 0)
                return error.FailedToDecodeResponse;

            return RPCResponse([]const u8).fromJson(value.arena, decoded_text[0]);
        }
    };
}

test "ENS Text" {
    const uri = try std.Uri.parse("http://localhost:8545/");

    var ens: ENSClient(.http) = undefined;
    defer ens.deinit();

    try ens.init(
        .{ .uri = uri, .allocator = testing.allocator },
        .{ .ensUniversalResolver = try utils.addressToBytes("0x8cab227b1162f03b8338331adaad7aadc83b895e") },
    );

    try testing.expectError(error.EvmFailedToExecute, ens.getEnsText("zzabi.eth", "com.twitter", .{}));
}

test "ENS Name" {
    {
        const uri = try std.Uri.parse("http://localhost:8545/");

        var ens: ENSClient(.http) = undefined;
        defer ens.deinit();

        try ens.init(
            .{ .uri = uri, .allocator = testing.allocator },
            .{ .ensUniversalResolver = try utils.addressToBytes("0x8cab227b1162f03b8338331adaad7aadc83b895e") },
        );

        const value = try ens.getEnsName("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", .{});
        defer value.deinit();

        try testing.expectEqualStrings(value.response, "vitalik.eth");
        try testing.expectError(error.EvmFailedToExecute, ens.getEnsName("0xD9DA6Bf26964af9d7Eed9e03e53415D37aa96045", .{}));
    }
    {
        const uri = try std.Uri.parse("http://localhost:8545/");

        var ens: ENSClient(.http) = undefined;
        defer ens.deinit();

        try ens.init(
            .{ .uri = uri, .allocator = testing.allocator },
            .{ .ensUniversalResolver = try utils.addressToBytes("0x9cab227b1162f03b8338331adaad7aadc83b895e") },
        );

        try testing.expectError(error.EvmFailedToExecute, ens.getEnsName("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", .{}));
    }
}

test "ENS Address" {
    const uri = try std.Uri.parse("http://localhost:8545/");

    var ens: ENSClient(.http) = undefined;
    defer ens.deinit();

    try ens.init(
        .{ .uri = uri, .allocator = testing.allocator },
        .{ .ensUniversalResolver = try utils.addressToBytes("0x8cab227b1162f03b8338331adaad7aadc83b895e") },
    );

    const value = try ens.getEnsAddress("vitalik.eth", .{});
    defer value.deinit();

    try testing.expectEqualSlices(u8, &value.response, &try utils.addressToBytes("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"));
    try testing.expectError(error.EvmFailedToExecute, ens.getEnsAddress("zzabi.eth", .{}));
}

test "ENS Resolver" {
    const uri = try std.Uri.parse("http://localhost:8545/");

    var ens: ENSClient(.http) = undefined;
    defer ens.deinit();

    try ens.init(
        .{ .uri = uri, .allocator = testing.allocator },
        .{ .ensUniversalResolver = try utils.addressToBytes("0x8cab227b1162f03b8338331adaad7aadc83b895e") },
    );

    const value = try ens.getEnsResolver("vitalik.eth", .{});

    try testing.expectEqualSlices(u8, &try utils.addressToBytes("0x4976fb03C32e5B8cfe2b6cCB31c09Ba78EBaBa41"), &value);
}
