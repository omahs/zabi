const abitype = @import("abi/abi.zig");
const meta = @import("meta/meta.zig");
const testing = std.testing;
const transaction = @import("meta/transaction.zig");
const types = @import("meta/ethereum.zig");
const std = @import("std");
const Anvil = @import("tests/Anvil.zig");
const Allocator = std.mem.Allocator;
const Wallet = @import("Wallet.zig");

pub const Contract = struct {
    wallet: *Wallet,

    abi: abitype.Abi,

    pub fn deinit(self: *Contract) void {
        self.wallet.deinit();
    }

    pub fn deployContract(self: *Contract, constructor_args: anytype, bytecode: []const u8, overrides: transaction.PrepareEnvelope) !types.Hex {
        var copy = overrides;
        const constructor = try self.getAbiItem(.constructor, null);
        const code = if (std.mem.startsWith(u8, bytecode, "0x")) bytecode[2..] else bytecode;

        const encoded = try constructor.abiConstructor.encode(self.wallet.alloc, constructor_args);
        defer if (encoded.len != 0) self.wallet.alloc.free(encoded);

        const concated = try std.fmt.allocPrint(self.wallet.alloc, "0x{s}{s}", .{ code, std.fmt.fmtSliceHexLower(encoded) });
        defer self.wallet.alloc.free(concated);

        switch (copy) {
            inline else => |*tx| {
                if (tx.to != null)
                    return error.CreatingContractToKnowAddress;

                const value = tx.value orelse 0;
                switch (constructor.abiConstructor.stateMutability) {
                    .nonpayable => if (value != 0)
                        return error.ValueInNonPayableConstructor,
                    .payable => {},
                }

                tx.data = concated;
            },
        }

        return self.wallet.sendTransaction(copy);
    }

    pub fn readContractFunction(self: *Contract, function_name: []const u8, function_args: anytype, overrides: transaction.EthCall) !types.Hex {
        const function_item = try self.getAbiItem(.function, function_name);
        var copy = overrides;

        switch (function_item.abiFunction.stateMutability) {
            .view, .pure => {},
            inline else => return error.InvalidFunctionMutability,
        }

        const encoded = try function_item.abiFunction.encode(self.wallet.alloc, function_args);
        defer if (encoded.len != 0) self.wallet.alloc.free(encoded);

        const concated = try std.fmt.allocPrint(self.wallet.alloc, "0x{s}", .{encoded});
        defer self.wallet.alloc.free(concated);

        switch (copy) {
            inline else => |*tx| {
                if (tx.to == null)
                    return error.InvalidRequestTarget;

                tx.data = concated;
            },
        }

        return self.wallet.pub_client.sendEthCall(copy, .{});
    }

    pub fn writeContractFunction(self: *Contract, function_name: []const u8, function_args: anytype, overrides: transaction.PrepareEnvelope) !types.Hex {
        const function_item = try self.getAbiItem(.function, function_name);
        var copy = overrides;

        switch (function_item.abiFunction.stateMutability) {
            .nonpayable, .payable => {},
            inline else => return error.InvalidFunctionMutability,
        }

        const encoded = try function_item.abiFunction.encode(self.wallet.alloc, function_args);
        defer if (encoded.len != 0) self.wallet.alloc.free(encoded);

        const concated = try std.fmt.allocPrint(self.wallet.alloc, "0x{s}", .{encoded});
        defer self.wallet.alloc.free(concated);

        switch (copy) {
            inline else => |*tx| {
                if (tx.to == null)
                    return error.InvalidRequestTarget;

                tx.data = concated;
            },
        }

        return self.wallet.sendTransaction(copy);
    }

    fn getAbiItem(self: Contract, abi_type: abitype.Abitype, name: ?[]const u8) !abitype.AbiItem {
        switch (abi_type) {
            .constructor => {
                for (self.abi) |abi_item| {
                    switch (abi_item) {
                        .abiConstructor => return abi_item,
                        inline else => continue,
                    }
                }
            },
            .function => {
                for (self.abi) |abi_item| {
                    switch (abi_item) {
                        .abiFunction => |function| {
                            if (std.mem.eql(u8, name.?, function.name))
                                return abi_item;

                            continue;
                        },
                        inline else => continue,
                    }
                }
            },
            .event => {
                for (self.abi) |abi_item| {
                    switch (abi_item) {
                        .abiEvent => |event| {
                            if (std.mem.eql(u8, name.?, event.name))
                                return abi_item;
                        },
                        inline else => continue,
                    }
                }
            },
            .@"error" => {
                for (self.abi) |abi_item| {
                    switch (abi_item) {
                        .abiError => |err| {
                            if (std.mem.eql(u8, name.?, err.name))
                                return abi_item;
                        },
                        inline else => continue,
                    }
                }
            },
            inline else => return error.NotSupported,
        }

        return error.AbiItemNotFound;
    }
};

fn AbiConstructorArgs(comptime constructor: abitype.Constructor) type {
    return struct { args: meta.AbiParametersToPrimative(constructor.inputs), bytecode: []const u8, wallet: *Wallet, overrides: transaction.PrepareEnvelope };
}

pub fn deployContract(comptime constructor: abitype.Constructor, opts: AbiConstructorArgs(constructor)) !types.Hex {
    const code = if (std.mem.startsWith(u8, opts.bytecode, "0x")) opts.bytecode[2..] else opts.bytecode;
    var copy = opts.overrides;

    const encoded = try constructor.encode(opts.wallet.alloc, opts.args);
    defer if (encoded.len != 0) opts.wallet.alloc.free(encoded);

    const concated = try std.fmt.allocPrint(opts.wallet.alloc, "0x{s}{s}", .{ code, std.fmt.fmtSliceHexLower(encoded) });
    defer opts.wallet.alloc.free(concated);

    switch (copy) {
        inline else => |*tx| {
            if (tx.to != null)
                return error.CreatingContractToKnowAddress;

            const value = tx.value orelse 0;
            switch (constructor.stateMutability) {
                .nonpayable => if (value != 0)
                    return error.ValueInNonPayableConstructor,
                .payable => {},
            }

            tx.data = concated;
        },
    }

    return opts.wallet.sendTransaction(copy);
}

fn AbiFunctionArgs(comptime function: abitype.Function, comptime Overrides: type) type {
    return struct { args: meta.AbiParametersToPrimative(function.inputs), wallet: *Wallet, overrides: Overrides };
}

pub fn readContractFunction(comptime function: abitype.Function, opts: AbiFunctionArgs(function, transaction.EthCall)) !types.Hex {
    switch (function.stateMutability) {
        .view, .pure => {},
        inline else => return error.InvalidFunctionMutability,
    }
    var copy = opts.overrides;

    const encoded = try function.encode(opts.wallet.alloc, opts.args);
    defer if (encoded.len != 0) opts.wallet.alloc.free(encoded);

    const concated = try std.fmt.allocPrint(opts.wallet.alloc, "0x{s}", .{encoded});
    defer opts.wallet.alloc.free(concated);

    switch (copy) {
        inline else => |*tx| {
            if (tx.to == null)
                return error.InvalidRequestTarget;

            tx.data = concated;
        },
    }

    return opts.wallet.pub_client.sendEthCall(copy, .{});
}

pub fn writeContractFunction(comptime function: abitype.Function, opts: AbiFunctionArgs(function, transaction.PrepareEnvelope)) !types.Hex {
    switch (function.stateMutability) {
        .payable, .nonpayable => {},
        inline else => return error.InvalidFunctionMutability,
    }
    var copy = opts.overrides;

    const encoded = try function.encode(opts.wallet.alloc, opts.args);
    defer if (encoded.len != 0) opts.wallet.alloc.free(encoded);

    const concated = try std.fmt.allocPrint(opts.wallet.alloc, "0x{s}", .{encoded});
    defer opts.wallet.alloc.free(concated);

    switch (copy) {
        inline else => |*tx| {
            if (tx.to == null)
                return error.InvalidRequestTarget;

            tx.data = concated;
        },
    }

    return opts.wallet.sendTransaction(copy);
}

test "DeployContract" {
    var contract: Contract = .{
        .abi = &.{.{ .abiConstructor = .{ .type = .constructor, .inputs = &.{}, .stateMutability = .nonpayable } }},
        .wallet = try Wallet.init(std.testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .ethereum),
    };
    defer contract.deinit();

    const hash = try contract.deployContract(.{}, "0x608060405260358060116000396000f3006080604052600080fd00a165627a7a72305820f86ff341f0dff29df244305f8aa88abaf10e3a0719fa6ea1dcdd01b8b7d750970029", .{ .eip1559 = .{} });

    try testing.expectEqual(hash.len, 66);
}

test "ReadContract" {
    {
        var contract: Contract = .{
            .abi = &.{.{ .abiFunction = .{ .type = .function, .inputs = &.{.{ .type = .{ .uint = 256 }, .name = "tokenId" }}, .stateMutability = .view, .outputs = &.{.{ .type = .{ .address = {} }, .name = "" }}, .name = "ownerOf" } }},
            .wallet = try Wallet.init(std.testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .ethereum),
        };
        defer contract.deinit();
        const result = try contract.readContractFunction("ownerOf", .{69}, .{ .eip1559 = .{ .to = "0x5Af0D9827E0c53E4799BB226655A1de152A425a5", .from = try contract.wallet.getWalletAddress() } });
        try testing.expectEqual(result.len, 66);
    }
    {
        var wallet = try Wallet.init(std.testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .ethereum);
        defer wallet.deinit();

        const result = try readContractFunction(.{ .type = .function, .inputs = &.{.{ .type = .{ .uint = 256 }, .name = "tokenId" }}, .stateMutability = .view, .outputs = &.{.{ .type = .{ .address = {} }, .name = "" }}, .name = "ownerOf" }, .{ .wallet = wallet, .args = .{69}, .overrides = .{ .eip1559 = .{ .to = "0x5Af0D9827E0c53E4799BB226655A1de152A425a5", .from = try wallet.getWalletAddress() } } });

        try testing.expectEqual(result.len, 66);
    }
}

test "WriteContract" {
    {
        var contract: Contract = .{
            .abi = &.{.{ .abiFunction = .{ .type = .function, .inputs = &.{ .{ .type = .{ .address = {} }, .name = "operator" }, .{ .type = .{ .bool = {} }, .name = "approved" } }, .stateMutability = .nonpayable, .outputs = &.{}, .name = "setApprovalForAll" } }},
            .wallet = try Wallet.init(std.testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .ethereum),
        };
        defer contract.deinit();
        var anvil: Anvil = undefined;
        defer anvil.deinit();

        try anvil.initClient(.{ .fork_url = "", .alloc = testing.allocator });
        try anvil.impersonateAccount("0xA207CDAf9b660960F819466BA69c28E7Cc8aEd18");

        const result = try contract.writeContractFunction("setApprovalForAll", .{ "0x19bb64b80CbF61E61965B0E5c2560CC7364c6546", true }, .{ .eip1559 = .{ .to = "0x5Af0D9827E0c53E4799BB226655A1de152A425a5" } });

        try anvil.stopImpersonatingAccount("0xA207CDAf9b660960F819466BA69c28E7Cc8aEd18");
        try testing.expectEqual(result.len, 66);
    }
    {
        var wallet = try Wallet.init(std.testing.allocator, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "http://localhost:8545", .ethereum);
        var anvil: Anvil = undefined;
        defer wallet.deinit();
        defer anvil.deinit();

        try anvil.initClient(.{ .fork_url = "", .alloc = testing.allocator });
        try anvil.impersonateAccount("0xA207CDAf9b660960F819466BA69c28E7Cc8aEd18");

        const result = try writeContractFunction(.{ .type = .function, .inputs = &.{ .{ .type = .{ .address = {} }, .name = "operator" }, .{ .type = .{ .bool = {} }, .name = "approved" } }, .stateMutability = .nonpayable, .outputs = &.{}, .name = "setApprovalForAll" }, .{ .args = .{ "0x19bb64b80CbF61E61965B0E5c2560CC7364c6547", true }, .overrides = .{ .eip1559 = .{ .to = "0x5Af0D9827E0c53E4799BB226655A1de152A425a5" } }, .wallet = wallet });

        try anvil.stopImpersonatingAccount("0xA207CDAf9b660960F819466BA69c28E7Cc8aEd18");
        try testing.expectEqual(result.len, 66);
    }
}
