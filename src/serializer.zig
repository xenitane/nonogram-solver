const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
fn SplitIteratorScalar(comptime T: type) type {
    return std.mem.SplitIterator(T, .scalar);
}

const Block = types.Block;
const NonogramInput = types.NonogramInput;
const SerializationError = errors.SerializationError;

pub fn serializeFileFromPath(ac: Allocator, file_path: []const u8) !NonogramInput {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    return serializeFile(ac, file);
}

pub fn serializeFile(ac: Allocator, file: std.fs.File) !NonogramInput {
    const file_content_raw = try file.readToEndAlloc(ac, 1 << 20);
    defer ac.free(file_content_raw);
    const file_content = trimWhiteSpace(file_content_raw);
    return serializeContent(ac, file_content);
}

fn trimWhiteSpace(buf: []const u8) []const u8 {
    return std.mem.trim(u8, buf, &std.ascii.whitespace);
}

pub fn serializeContent(ac: Allocator, file_content: []const u8) !NonogramInput {
    var file_itr = std.mem.splitScalar(u8, file_content, '\n');

    var dims = std.mem.splitScalar(u8, trimWhiteSpace(file_itr.next() orelse return SerializationError.InvalidInput), ',');
    var rows = std.mem.splitScalar(u8, trimWhiteSpace(file_itr.next() orelse return SerializationError.InvalidInput), '|');
    var cols = std.mem.splitScalar(u8, trimWhiteSpace(file_itr.next() orelse return SerializationError.InvalidInput), '|');

    if (file_itr.next() != null) {
        return SerializationError.ExtraLines;
    }

    var res: NonogramInput = undefined;
    res.ac = ac;

    try processDims(&res, &dims);

    res.row_inf = try processLines(ac, &rows, res.row_qty);
    res.col_inf = try processLines(ac, &cols, res.col_qty);

    return res;
}

fn processDims(out: *NonogramInput, itr: *SplitIteratorScalar(u8)) !void {
    out.row_qty = try std.fmt.parseInt(usize, trimWhiteSpace(itr.next() orelse return SerializationError.NoDimensionProvided), 10);
    out.col_qty = try std.fmt.parseInt(usize, trimWhiteSpace(itr.next() orelse return SerializationError.NoDimensionProvided), 10);
    if (itr.next() != null) {
        return SerializationError.ExtraDimension;
    }
}

fn processLines(ac: Allocator, itr: *SplitIteratorScalar(u8), qty: usize) ![][]Block {
    var i: usize = 0;
    var matrix = std.ArrayList([]Block).init(ac);
    errdefer {
        for (matrix.items) |line| {
            ac.free(line);
        }
        matrix.deinit();
    }
    while (itr.next()) |line_r| : (i += 1) {
        const line = trimWhiteSpace(line_r);
        if (line.len == 0) {
            try matrix.append(try ac.alloc(Block, 0));
        } else {
            var block_itr = std.mem.splitScalar(u8, line, ';');
            try matrix.append(try processLine(ac, &block_itr));
        }
    }
    if (i != qty) {
        return SerializationError.LineCountMismatch;
    }
    return matrix.toOwnedSlice();
}

fn processLine(ac: Allocator, block_itr: *SplitIteratorScalar(u8)) ![]Block {
    var block_list = std.ArrayList(Block).init(ac);
    errdefer block_list.deinit();
    while (block_itr.next()) |block_r| {
        const block = trimWhiteSpace(block_r);
        if (block.len == 0) {
            return SerializationError.EmptyBlock;
        }
        var block_info = std.mem.splitScalar(u8, block, ':');
        try block_list.append(try processBlock(&block_info));
    }
    return block_list.toOwnedSlice();
}

fn processBlock(block_info: *SplitIteratorScalar(u8)) !Block {
    const size = try std.fmt.parseInt(u32, trimWhiteSpace(block_info.next() orelse return SerializationError.BlockSizeNotPresent), 10);
    const color = try std.fmt.parseInt(u32, trimWhiteSpace(block_info.next() orelse "ff"), 16);
    if (block_info.next() != null) {
        return SerializationError.ExtraBlockParameters;
    }
    return .{ .size = size, .color = color };
}
