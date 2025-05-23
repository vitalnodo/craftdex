const std = @import("std");
const DexIR = @import("../ir.zig").ir.DexIR;
const StringPool = @import("StringPool.zig").StringPool;
const TypePool = @import("TypePool.zig").TypePool;
const NO_INDEX = @import("../ir.zig").ir.NO_INDEX;

pub const ClassDefItem = extern struct {
    class_idx: u32,
    access_flags: u32,
    superclass_idx: u32,
    interfaces_off: u32,
    source_file_idx: u32,
    annotations_off: u32,
    class_data_off: u32,
    static_values_off: u32,
};

pub const ClassDefEmitter = struct {
    list: std.ArrayList(ClassDefItem),

    pub fn init(allocator: std.mem.Allocator) !ClassDefEmitter {
        return .{
            .list = std.ArrayList(ClassDefItem).init(allocator),
        };
    }

    pub fn fromDexIR(
        self: *ClassDefEmitter,
        strings: *StringPool,
        types: *TypePool,
        ir: *const DexIR,
    ) !void {
        for (ir.classes) |class_ir| {
            _ = &strings;
            const class_idx = types.indexOf(class_ir.name) orelse return error.MissingType;
            const superclass_idx = types.indexOf(class_ir.superclass) orelse 0;
            const source_file_idx: u32 = NO_INDEX;

            const item = ClassDefItem{
                .class_idx = class_idx,
                .access_flags = class_ir.access_flags.toInt(),
                .superclass_idx = superclass_idx,
                .interfaces_off = 0,
                .source_file_idx = source_file_idx,
                .annotations_off = 0,
                .class_data_off = 0,
                .static_values_off = 0,
            };
            try self.list.append(item);
        }
    }

    pub fn setClassDataOff(self: *ClassDefEmitter, class_data_off: u32) void {
        for (self.list.items) |*c| {
            c.class_data_off = class_data_off;
        }
    }

    pub fn emit(self: *ClassDefEmitter, header_off: *u32, writer: anytype) !void {
        header_off.* = @intCast(try writer.context.getPos());
        for (self.list.items) |item| {
            try writer.writeStructEndian(item, .little);
        }
    }
};
