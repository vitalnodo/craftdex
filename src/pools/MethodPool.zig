const std = @import("std");
const StringPool = @import("StringPool.zig").StringPool;
const TypePool = @import("TypePool.zig").TypePool;
const ProtoPool = @import("ProtoPool.zig").ProtoPool;
const ProtoIR = @import("../ir.zig").ir.ProtoIR;
const DexIR = @import("../ir.zig").ir.DexIR;

pub const MethodKey = struct {
    class: []const u8,
    name: []const u8,
    proto: ProtoIR,
};

const MethodContext = struct {
    pub fn hash(_: MethodContext, key: MethodKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.class);
        hasher.update(key.name);
        hasher.update(key.proto.return_type);
        for (key.proto.parameters) |param| {
            hasher.update(param);
        }
        return hasher.final();
    }

    pub fn eql(_: MethodContext, a: MethodKey, b: MethodKey) bool {
        if (!std.mem.eql(u8, a.class, b.class)) return false;
        if (!std.mem.eql(u8, a.name, b.name)) return false;
        if (!std.mem.eql(u8, a.proto.return_type, b.proto.return_type)) return false;
        if (a.proto.parameters.len != b.proto.parameters.len) return false;
        for (a.proto.parameters, b.proto.parameters) |pa, pb| {
            if (!std.mem.eql(u8, pa, pb)) return false;
        }
        return true;
    }
};

const MethodIdItem = extern struct {
    class_idx: u16,
    proto_idx: u16,
    name_idx: u32,
};

pub const MethodPool = struct {
    allocator: std.mem.Allocator,
    unsorted: std.ArrayList(MethodKey),
    sorted: std.ArrayList(MethodKey),
    map: std.HashMap(MethodKey, u16, MethodContext, 80),

    pub fn init(allocator: std.mem.Allocator) !MethodPool {
        return MethodPool{
            .allocator = allocator,
            .unsorted = std.ArrayList(MethodKey).init(allocator),
            .sorted = std.ArrayList(MethodKey).init(allocator),
            .map = std.HashMap(MethodKey, u16, MethodContext, 80).init(allocator),
        };
    }

    pub fn add(
        self: *MethodPool,
        strings: *StringPool,
        types: *TypePool,
        protos: *ProtoPool,
        class: []const u8,
        name: []const u8,
        proto: ProtoIR,
    ) !u16 {
        _ = strings;
        _ = types;
        _ = protos;
        const key = MethodKey{ .class = class, .name = name, .proto = proto };
        if (self.map.get(key)) |idx| return idx;

        const new_idx: u16 = @intCast(self.unsorted.items.len);
        try self.unsorted.append(key);
        try self.map.put(key, new_idx);
        return new_idx;
    }

    pub fn sort(self: *MethodPool) !void {
        try self.sorted.appendSlice(self.unsorted.items);
        std.mem.sort(MethodKey, self.sorted.items, {}, struct {
            pub fn lessThan(_: void, a: MethodKey, b: MethodKey) bool {
                const class_cmp = std.mem.order(u8, a.class, b.class);
                if (class_cmp != .eq) return class_cmp == .lt;

                const name_cmp = std.mem.order(u8, a.name, b.name);
                if (name_cmp != .eq) return name_cmp == .lt;

                const proto_cmp = compareProto(a.proto, b.proto);
                return proto_cmp == .lt;
            }

            pub fn compareProto(a: ProtoIR, b: ProtoIR) std.math.Order {
                const ret_cmp = std.mem.order(u8, a.return_type, b.return_type);
                if (ret_cmp != .eq) return ret_cmp;

                const min_len = @min(a.parameters.len, b.parameters.len);
                for (0..min_len) |i| {
                    const p_cmp = std.mem.order(u8, a.parameters[i], b.parameters[i]);
                    if (p_cmp != .eq) return p_cmp;
                }
                return std.math.order(a.parameters.len, b.parameters.len);
            }
        }.lessThan);
    }

    pub fn emitMethodIds(
        self: *MethodPool,
        strings: *StringPool,
        types: *TypePool,
        protos: *ProtoPool,
        stream: anytype,
    ) !void {
        const writer = stream.writer();
        for (self.sorted.items) |key| {
            const class_idx = types.indexOf(key.class) orelse return error.TypeNotFound;
            const name_idx = strings.indexOf(key.name) orelse return error.StringNotFound;
            const proto_idx = protos.indexOf(key.proto.parameters, key.proto.return_type) orelse return error.ProtoIndexNotFound;

            try writer.writeStructEndian(MethodIdItem{
                .class_idx = @intCast(class_idx),
                .proto_idx = @intCast(proto_idx),
                .name_idx = name_idx,
            }, .little);
        }
    }

    pub fn fromDexIR(
        self: *MethodPool,
        strings: *StringPool,
        types: *TypePool,
        protos: *ProtoPool,
        ir: *const DexIR,
    ) !void {
        for (ir.classes) |class_ir| {
            for (class_ir.methods) |method_ir| {
                for (method_ir.code) |instr| {
                    if (instr.operand) |op| {
                        switch (op) {
                            .reference => |ref| switch (ref) {
                                .method => |m| {
                                    const idx = protos.indexOf(m.proto.parameters, m.proto.return_type) orelse return error.ProtoIndexMissing;
                                    const proto = protos.list.items[idx];
                                    _ = try self.add(strings, types, protos, m.class, m.name, proto);
                                },
                                else => {},
                            },
                            else => {},
                        }
                    }
                }
            }
        }

        for (ir.classes) |class_ir| {
            for (class_ir.methods) |method_ir| {
                _ = try self.add(strings, types, protos, class_ir.name, method_ir.name, method_ir.proto);
            }
        }
    }

    pub fn indexOf(self: *const MethodPool, key: MethodKey) ?u16 {
        for (self.sorted.items, 0..) |item, i| {
            if (MethodContext.eql(undefined, item, key)) return @intCast(i);
        }
        return null;
    }
};
