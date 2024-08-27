const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const MultiArrayList = std.MultiArrayList;
const AutoHashMap = std.AutoHashMap;

pub const BlockInfo = struct { size: usize, color: u8 };
pub const NonogramSolution = struct {
    grid: [][]u8,
    grid_bytes: []u8,
    ac: Allocator,
    const Self = @This();
    fn deinit(self: Self) void {
        self.ac.free(self.grid_bytes);
        self.ac.free(self.grid);
    }
};

pub const LineInfo = MultiArrayList(BlockInfo);

fn inSlice(comptime T: type, slice: []const T, target: T) bool {
    for (slice, 0..) |_, i| {
        if (target == slice[i]) {
            return true;
        }
    }
    return false;
}

pub fn createLineInfo(ac: Allocator, len: usize) ![]LineInfo {
    const res = try ac.alloc(LineInfo, len);
    for (res, 0..) |_, i| {
        res[i] = LineInfo{};
    }
    return res;
}

pub const Nonogram = struct {
    row_length: usize,
    col_length: usize,
    row_info: []LineInfo,
    col_info: []LineInfo,
    ac: Allocator,

    const Self = @This();
    pub const NonogramErrors = error{
        InvalidData,
        InvalidIndex,
        InvalidLineData,
        LineDataAlreadyExist,
        PixelCountMismatch,
        Unsolvable,
    };

    pub fn init(ac: Allocator, r: usize, c: usize) !Self {
        if ((r == 0) or (c == 0)) {
            return NonogramErrors.InvalidData;
        }
        const row_inf = try createLineInfo(ac, r);
        const col_inf = try createLineInfo(ac, c);
        return .{
            .row_length = r,
            .row_info = row_inf,
            .col_length = c,
            .col_info = col_inf,
            .ac = ac,
        };
    }

    fn deinit(self: *Self) void {
        for (self.row_info, 0..) |_, i| {
            self.row_info[i].deinit(self.ac);
        }
        self.ac.free(self.row_info);
        for (self.col_info, 0..) |_, i| {
            self.col_info[i].deinit(self.ac);
        }
        self.ac.free(self.col_info);

        self.* = undefined;
    }

    fn validate(self: *const Self) !bool {
        var pixel_frq = AutoHashMap(u8, usize).init(self.ac);
        defer pixel_frq.deinit();
        for (self.row_info) |row| {
            if (0 == row.len) {
                continue;
            }
            var pixel_count: usize = 0;
            var prev_block = row.get(0);
            for (row.items(.color), row.items(.size)) |cl, sz| {
                if (pixel_frq.get(cl) == null) {
                    try pixel_frq.put(cl, 0);
                }
                pixel_frq.getPtr(cl).?.* += sz;
                pixel_count += sz;
                if (cl != prev_block.color) {
                    pixel_count += 1;
                }
                prev_block = .{ .size = sz, .color = cl };
            }
            if (pixel_count > self.col_length) {
                return NonogramErrors.InvalidLineData;
            }
        }
        for (self.col_info) |col| {
            if (0 == col.len) {
                continue;
            }
            var pixel_count: usize = 0;
            var prev_block = col.get(0);
            for (col.items(.color), col.items(.size)) |cl, sz| {
                const frq = pixel_frq.getPtr(cl);
                if ((frq == null) or (frq.?.* < sz)) {
                    return false;
                }
                frq.?.* -= sz;
                if (frq.?.* == 0) {
                    _ = pixel_frq.remove(cl);
                }
                pixel_count += sz;
                if (cl != prev_block.color) {
                    pixel_count += 1;
                }
                prev_block = .{ .size = sz, .color = cl };
            }
            if (pixel_count > self.row_length) {
                return NonogramErrors.InvalidLineData;
            }
        }
        return pixel_frq.count() == 0;
    }

    // don't forget to free memory of the solution
    fn solve(self: *Self) !NonogramSolution {
        if (!(try self.validate())) {
            return NonogramErrors.PixelCountMismatch;
        }
        const state = try self.ac.alloc([]u8, self.row_length);
        const state_bytes = try self.ac.alloc(u8, self.row_length * self.col_length);
        const state_marker = try self.ac.alloc(u8, @max(self.row_length, self.col_length));
        errdefer {
            self.ac.free(state_bytes);
            self.ac.free(state);
            self.ac.free(state_marker);
        }
        defer self.ac.free(state_marker);
        @memset(state_bytes, 0);
        for (state, 0..) |_, i| {
            state[i] = state_bytes[(i * self.col_length)..((i + 1) * self.col_length)];
        }
        while (true) {
            var res: bool = false;
            for (self.row_info, 0..) |_, i| {
                @memcpy(state_marker[0..self.col_length], state[i]);
                const is_line_modified = try solveLine(self.ac, state_marker[0..self.col_length], self.row_info[i]);
                if (is_line_modified) {
                    res = true;
                    @memcpy(state[i], state_marker[0..self.col_length]);
                }
            }
            for (self.col_info, 0..) |_, i| {
                for (0..self.row_length) |j| {
                    state_marker[self.col_length + j] = state[j][i];
                }
                const is_line_modified = try solveLine(self.ac, state_marker[self.col_length..], self.row_info[i]);
                if (is_line_modified) {
                    res = true;
                    for (0..self.col_length) |j| {
                        state[j][i] = state_marker[self.col_length + j];
                    }
                }
            }
            if (!res) {
                return NonogramErrors.Unsolvable;
            }
            if (@reduce(.And, state_bytes) != 0) {
                break;
            }
            break;
        }
        return .{
            .grid = state,
            .grid_bytes = state_bytes,
            .ac = self.ac,
        };
    }
};

const DP = AutoHashMap(struct { usize, usize, usize, u8 }, bool);

fn solveLine(ac: Allocator, state: []u8, line_info: LineInfo) !bool {
    const iterable_state_res = try ac.alloc(u8, state.len);
    const iterable_state_itr = try ac.alloc(u8, state.len);
    defer ac.free(iterable_state_itr);
    defer ac.free(iterable_state_res);

    var dynamic_data: DP = DP.init(ac);
    defer dynamic_data.deinit();

    _ = try solveLineMain(dynamic_data, state, .{ iterable_state_res, iterable_state_itr }, line_info, 0, 0xff, 0, 0);
    if (line_info.len > 0) {
        _ = try solveLineMain(dynamic_data, state, .{ iterable_state_res, iterable_state_itr }, line_info, 0, line_info.get(0).color, 0, 0);
    }
    if (std.mem.eql(u8, state, iterable_state_res)) {
        return false;
    }
    @memcpy(state, iterable_state_res);
    return true;
}

fn solveLineMain(dynamic_data: DP, original_state: []const u8, iterable_state: struct { []u8, []u8 }, line_info: LineInfo, idx: usize, to_fill: u8, block_idx: usize, cells_filled: usize) !bool {
    if ((idx <= original_state.len) and (block_idx <= line_info.len) and (cells_filled <= original_state.len)) {
        if (!dynamic_data.contains(.{ idx, block_idx, cells_filled, to_fill })) {
            if (idx == original_state.len) {
                const res = if ((block_idx == line_info.len) and (cells_filled == 0)) true else false;
                try dynamic_data.put(.{ idx, block_idx, cells_filled, to_fill }, res);
            } else if (block_idx == line_info.len) {
                const res = switch (original_state[idx]) {
                    0x00, 0xff => ffblk: {
                        defer iterable_state[1][idx] = 0;
                        iterable_state[1][idx] = 0xff;
                        break :ffblk try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, 0xff, block_idx, 0);
                    },
                    else => false,
                };
                try dynamic_data.put(.{ idx, block_idx, cells_filled, to_fill }, res);
            } else {
                const res = switch (original_state[idx]) {
                    0x00 => blk00: {
                        defer iterable_state[1][idx] = 0;
                        var res_00 = false;
                        if (to_fill == 0xff) {
                            if (cells_filled == line_info.get(block_idx).size) {
                                //

                            } else {
                                //
                            }
                        } else {
                            //
                            res_00 = res_00 or (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, 0xff, block_idx, 0));
                        }
                        break :blk00 res_00;
                    },
                    0xff => blkff: {
                        if (to_fill != 0xff) {
                            break :blkff false;
                        }
                        defer iterable_state[1][idx] = 0;
                        var res_ff = false;

                        iterable_state[1][idx] = 0xff;
                        res_ff = res_ff or (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, 0xff, block_idx, 0));
                        res_ff = res_ff or (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, line_info.get(block_idx).color, block_idx, 1));
                        break :blkff res_ff;
                    },
                    else => blkelse: {
                        const block_info = line_info.get(block_idx);
                        if ((to_fill != block_info.color) or (to_fill != original_state[idx])) {
                            break :blkelse false;
                        }
                        defer iterable_state[1][idx] = 0;
                        var res_else = false;

                        iterable_state[1][idx] = original_state[idx];
                        if (line_info.get(block_idx).size == cells_filled) {
                            res_else = res_else or try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, 0xff, block_idx + 1, 0);
                            if ((block_idx + 1 != line_info.len) and (to_fill != line_info.get(block_idx + 1).color)) {
                                res_else = res_else or (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, line_info.get(block_idx + 1).color, block_idx + 1, 1));
                            }
                        } else {
                            res_else = try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, to_fill, block_idx, cells_filled + 1);
                        }
                        break :blkelse res_else;
                    },
                };
                try dynamic_data.put(.{ idx, block_idx, cells_filled, to_fill }, res);
            }
        }
        const res = dynamic_data.get(.{ idx, block_idx, cells_filled, to_fill }).?;
        if (res and (idx > 0) and (iterable_state[0][idx - 1] != iterable_state[1][idx - 1])) {
            iterable_state[0][idx - 1] = 0;
        }
        return res;
    } else {
        return false;
    }
}

fn update_state_data(state_data: struct { []u8, []u8 }, till: usize) void {
    for (0..till) |i| {
        if (state_data[0][i] != state_data[1][i]) {
            state_data[0][i] = 0;
        }
    }
}

const testing = std.testing;
const ally = testing.allocator;

test "testing in slice" {
    const data = &[_]u8{ 0, 1, 2, 3, 4, 5 };
    var res: bool = undefined;
    res = inSlice(u8, data, 4);
    try testing.expectEqual(true, res);
    res = inSlice(u8, data, 10);
    try testing.expectEqual(false, res);
}

test "solve line test" {
    var line_info = LineInfo{};
    defer line_info.deinit(ally);
    try line_info.append(ally, .{ .size = 1, .color = 1 });
    try line_info.append(ally, .{ .size = 1, .color = 1 });
    const state = try ally.alloc(u8, 3);
    defer ally.free(state);
    @memset(state, 0);
    try testing.expectEqual(true, try solveLine(ally, state, line_info));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0xff, 0x01 }, state);
}

test "nonogram tests" {
    var ng = try Nonogram.init(ally, 5, 5);
    defer ng.deinit();

    try ng.row_info[0].append(ally, .{ .size = 5, .color = 1 });
    try ng.row_info[1].append(ally, .{ .size = 5, .color = 1 });
    try ng.row_info[2].append(ally, .{ .size = 5, .color = 1 });
    try ng.row_info[3].append(ally, .{ .size = 5, .color = 1 });
    try ng.row_info[4].append(ally, .{ .size = 5, .color = 1 });

    try ng.col_info[0].append(ally, .{ .size = 5, .color = 1 });
    try ng.col_info[1].append(ally, .{ .size = 5, .color = 1 });
    try ng.col_info[2].append(ally, .{ .size = 5, .color = 1 });
    try ng.col_info[3].append(ally, .{ .size = 5, .color = 1 });
    try ng.col_info[4].append(ally, .{ .size = 5, .color = 1 });

    try testing.expectEqual(true, try ng.validate());

    // const nonogram_solution = try ng.solve();
    // try testing.expectEqualSlices(u8, &[_]u8{1} ** 25, nonogram_solution.grid_bytes);
}
