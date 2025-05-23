const std = @import("std");
const testing = std.testing;

pub const Opcode = enum(u8) {
    return_void = 0x0e,
    const_string = 0x1a,
    invoke_virtual = 0x6e,
    invoke_direct = 0x70,
    invoke_super = 0x6f,
    new_instance = 0x22,
};

const OpcodeMapEntry = struct { []const u8, Opcode };
pub const opcode_map = std.StaticStringMap(
    Opcode,
).initComptime(
    &[_]OpcodeMapEntry{
        .{ "return-void", .return_void },
        .{ "const-string", .const_string },
        .{ "invoke-virtual", .invoke_virtual },
        .{ "invoke-direct", .invoke_direct },
        .{ "invoke-super", .invoke_super },
        .{ "new-instance", .new_instance },
    },
);

pub const Instruction = union(enum) {
    return_void: Format10x,
    const_string: Format21c,
    new_instance: Format21c,
    invoke_direct: Format35c,
    invoke_virtual: Format35c,
    invoke_super: Format35c,

    pub fn emit(self: Instruction, writer: anytype) !void {
        return switch (self) {
            .return_void => |v| v.emitWithOpcode(writer, .return_void),
            .const_string => |v| v.emitWithOpcode(writer, .const_string),
            .new_instance => |v| v.emitWithOpcode(writer, .new_instance),
            .invoke_direct => |v| v.emitWithOpcode(writer, .invoke_direct),
            .invoke_virtual => |v| v.emitWithOpcode(writer, .invoke_virtual),
            .invoke_super => |v| v.emitWithOpcode(writer, .invoke_super),
        };
    }
};

pub const Format10x = struct {
    pub fn emitWithOpcode(self: @This(), writer: anytype, opcode: Opcode) !void {
        _ = self;
        try writer.writeAll(&.{ @intFromEnum(opcode), 0x00 });
    }
};

pub const Format21c = struct {
    reg: u8,
    idx: u16,

    pub fn emitWithOpcode(self: @This(), writer: anytype, opcode: Opcode) !void {
        try writer.writeByte(@intFromEnum(opcode));
        try writer.writeByte(self.reg);
        try writer.writeInt(u16, self.idx, .little);
    }
};

pub const Format35c = struct {
    method_idx: u16,
    reg_count: u8 = 0,
    reg_c: u8 = 0,
    reg_d: u8 = 0,
    reg_e: u8 = 0,
    reg_f: u8 = 0,
    reg_g: u8 = 0,

    pub fn emitWithOpcode(self: @This(), writer: anytype, opcode: Opcode) !void {
        try writer.writeByte(@intFromEnum(opcode));
        try writer.writeByte((self.reg_count << 4) | self.reg_g);
        try writer.writeInt(u16, self.method_idx, .little);
        try writer.writeByte((self.reg_d << 4) | self.reg_c);
        try writer.writeByte((self.reg_f << 4) | self.reg_e);
    }
};
