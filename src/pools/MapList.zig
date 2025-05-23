const std = @import("std");
const Section = @import("../emitter.zig").Section;
const SectionEnum = @import("../emitter.zig").SectionEnum;
const ir = @import("../ir.zig").ir;
const StringPool = @import("StringPool.zig").StringPool;

pub const MapList = struct {
    pub fn stringToMapItemType(section: SectionEnum) ?ir.MapItemType {
        const t = ir.MapItemType;
        return switch (section) {
            .StringIds => t.TYPE_STRING_ID_ITEM,
            .TypeIds => t.TYPE_TYPE_ID_ITEM,
            .ProtoIds => t.TYPE_PROTO_ID_ITEM,
            .MethodIds => t.TYPE_METHOD_ID_ITEM,
            .ClassDefs => t.TYPE_CLASS_DEF_ITEM,
            .StringData => t.TYPE_STRING_DATA_ITEM,
            .TypeList => t.TYPE_TYPE_LIST,
            .AnnotationSet => t.TYPE_ANNOTATION_SET_ITEM,
            .CodeItem => t.TYPE_CODE_ITEM,
            .ClassDataItem => t.TYPE_CLASS_DATA_ITEM,
            .MapList => t.TYPE_MAP_LIST,
            else => null,
        };
    }

    pub fn emit(
        writer: anytype,
        layout: []const Section,
        string_pool: *StringPool,
        method_len: u32,
    ) !void {
        try writer.writeInt(u32, @intCast(layout.len + 1), .little);

        // Header item
        try writer.writeInt(u16, 0x0000, .little); // type: HEADER_ITEM
        try writer.writeInt(u16, 0, .little); // unused
        try writer.writeInt(u32, 1, .little); // size
        try writer.writeInt(u32, 0, .little); // offset

        for (layout) |entry| {
            const count: u32 = switch (entry.name) {
                .StringIds => entry.size / 4,
                .TypeIds => entry.size / 4,
                .ProtoIds => entry.size / 12,
                .MethodIds => entry.size / 8,
                .ClassDefs => entry.size / 32,
                .TypeList => entry.size / 8,
                .StringData => @intCast(string_pool.list.items.len),
                .CodeItem => method_len,
                .AnnotationSet => 2,
                else => 1,
            };
            const type_ = stringToMapItemType(
                entry.name,
            ) orelse return error.UnknownMapItem;
            try writer.writeInt(u16, @intFromEnum(type_), .little);
            try writer.writeInt(u16, 0, .little);
            try writer.writeInt(u32, count, .little);
            try writer.writeInt(u32, entry.offset, .little);
        }
    }
};
