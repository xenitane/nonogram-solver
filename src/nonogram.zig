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
        }
        defer self.ac.free(state_marker);
        @memset(state_bytes, 0);
        for (state, 0..) |_, i| {
            state[i] = state_bytes[(i * self.col_length)..((i + 1) * self.col_length)];
        }
        var ii: u32 = 0;
        while (true) : (ii = ii + 1) {
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
                    state_marker[j] = state[j][i];
                }
                const is_line_modified = try solveLine(self.ac, state_marker[0..self.col_length], self.col_info[i]);
                if (is_line_modified) {
                    res = true;
                    for (0..self.col_length) |j| {
                        state[j][i] = state_marker[j];
                    }
                }
            }
            if (!res) {
                return NonogramErrors.Unsolvable;
            }
            if (all_non_zero(u8, state_bytes) or (ii == state_bytes.len)) {
                break;
            }
        }
        return .{
            .grid = state,
            .grid_bytes = state_bytes,
            .ac = self.ac,
        };
    }
};

fn all_non_zero(comptime T: type, data: []const T) bool {
    for (data) |d| {
        if (d == 0) {
            return false;
        }
    }
    return true;
}

const DP = AutoHashMap(struct { usize, usize, usize, u8 }, bool);

fn solveLine(ac: Allocator, state: []u8, line_info: LineInfo) !bool {
    const iterable_state_res = try ac.alloc(u8, state.len);
    const iterable_state_itr = try ac.alloc(u8, state.len);
    defer ac.free(iterable_state_itr);
    defer ac.free(iterable_state_res);

    @memset(iterable_state_res, 0);
    @memset(iterable_state_itr, 0);

    var dynamic_data: DP = DP.init(ac);
    defer dynamic_data.deinit();
    var tried = false;

    _ = (try solveLineMain(&dynamic_data, state, .{ iterable_state_res, iterable_state_itr }, line_info, 0, 0xff, 0, 0, &tried));
    if (line_info.len > 0) {
        _ = (try solveLineMain(&dynamic_data, state, .{ iterable_state_res, iterable_state_itr }, line_info, 0, line_info.get(0).color, 0, 1, &tried));
    }
    if (std.mem.eql(u8, state, iterable_state_res)) {
        return false;
    }
    @memcpy(state, iterable_state_res);
    return true;
}

fn zero_count(arr: []const u8) usize {
    var res: usize = 0;
    for (arr) |a| {
        res += if (a == 0) 1 else 0;
    }
    return res;
}

fn solveLineMain(dynamic_data: *DP, original_state: []const u8, iterable_state: struct { []u8, []u8 }, line_info: LineInfo, idx: usize, to_fill: u8, block_idx: usize, cells_filled: usize, tried: *bool) !bool {
    if ((idx <= original_state.len) and (block_idx <= line_info.len) and (cells_filled <= original_state.len)) {
        if (!dynamic_data.contains(.{ idx, block_idx, cells_filled, to_fill })) {
            if (idx == original_state.len) {
                const res = if ((block_idx == line_info.len) and (cells_filled == 0)) true else false;
                if (res and !tried.*) {
                    tried.* = true;
                    @memcpy(iterable_state[0], iterable_state[1]);
                }
                try dynamic_data.put(.{ idx, block_idx, cells_filled, to_fill }, res);
            } else if (block_idx == line_info.len) {
                const res = switch (original_state[idx]) {
                    0x00, 0xff => ffblk: {
                        defer iterable_state[1][idx] = 0;
                        iterable_state[1][idx] = 0xff;
                        break :ffblk try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, 0xff, block_idx, 0, tried);
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
                            iterable_state[1][idx] = to_fill;
                            if (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, 0xff, block_idx, 0, tried)) {
                                res_00 = true;
                            }
                            if (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, line_info.get(block_idx).color, block_idx, 1, tried)) {
                                res_00 = true;
                            }
                        } else {
                            const block_info = line_info.get(block_idx);
                            if (to_fill == block_info.color) {
                                iterable_state[1][idx] = to_fill;
                                if (cells_filled == line_info.get(block_idx).size) {
                                    if (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, 0xff, block_idx + 1, 0, tried)) {
                                        res_00 = true;
                                    }
                                    if ((block_idx + 1 != line_info.len) and (to_fill != line_info.get(block_idx + 1).color)) {
                                        if (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, line_info.get(block_idx + 1).color, block_idx + 1, 1, tried)) {
                                            res_00 = true;
                                        }
                                    }
                                } else {
                                    if (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, to_fill, block_idx, cells_filled + 1, tried)) {
                                        res_00 = true;
                                    }
                                }
                            }
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
                        if (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, 0xff, block_idx, 0, tried)) {
                            res_ff = true;
                        }
                        if (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, line_info.get(block_idx).color, block_idx, 1, tried)) {
                            res_ff = true;
                        }
                        break :blkff res_ff;
                    },
                    else => blkelse: {
                        const block_info = line_info.get(block_idx);
                        if ((to_fill != block_info.color) or (to_fill != original_state[idx])) {
                            break :blkelse false;
                        }
                        defer iterable_state[1][idx] = 0;
                        var res_else = false;

                        iterable_state[1][idx] = to_fill;
                        if (block_info.size == cells_filled) {
                            if (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, 0xff, block_idx + 1, 0, tried)) {
                                res_else = true;
                            }
                            if ((block_idx + 1 != line_info.len) and (to_fill != line_info.get(block_idx + 1).color)) {
                                if (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, line_info.get(block_idx + 1).color, block_idx + 1, 1, tried)) {
                                    res_else = true;
                                }
                            }
                        } else {
                            if (try solveLineMain(dynamic_data, original_state, iterable_state, line_info, idx + 1, to_fill, block_idx, cells_filled + 1, tried)) {
                                res_else = true;
                            }
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
    const res = try solveLine(ally, state, line_info);
    try testing.expectEqual(true, res);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0xff, 0x01 }, state);
}

test "nonogram tests" {
    var ng = try Nonogram.init(ally, 10, 10);
    defer ng.deinit();

    try ng.row_info[0].append(ally, .{ .size = 10, .color = 1 });

    try ng.row_info[1].append(ally, .{ .size = 1, .color = 1 });
    try ng.row_info[1].append(ally, .{ .size = 1, .color = 1 });

    try ng.row_info[2].append(ally, .{ .size = 1, .color = 1 });
    try ng.row_info[2].append(ally, .{ .size = 1, .color = 1 });
    try ng.row_info[2].append(ally, .{ .size = 1, .color = 1 });

    try ng.row_info[3].append(ally, .{ .size = 1, .color = 1 });
    try ng.row_info[3].append(ally, .{ .size = 3, .color = 1 });
    try ng.row_info[3].append(ally, .{ .size = 1, .color = 1 });

    try ng.row_info[4].append(ally, .{ .size = 1, .color = 1 });
    try ng.row_info[4].append(ally, .{ .size = 1, .color = 1 });

    try ng.row_info[5].append(ally, .{ .size = 1, .color = 1 });
    try ng.row_info[5].append(ally, .{ .size = 3, .color = 1 });
    try ng.row_info[5].append(ally, .{ .size = 1, .color = 1 });

    try ng.row_info[6].append(ally, .{ .size = 1, .color = 1 });
    try ng.row_info[6].append(ally, .{ .size = 1, .color = 1 });

    try ng.row_info[7].append(ally, .{ .size = 1, .color = 1 });
    try ng.row_info[7].append(ally, .{ .size = 3, .color = 1 });
    try ng.row_info[7].append(ally, .{ .size = 1, .color = 1 });

    try ng.row_info[8].append(ally, .{ .size = 1, .color = 1 });
    try ng.row_info[8].append(ally, .{ .size = 1, .color = 1 });

    try ng.row_info[9].append(ally, .{ .size = 10, .color = 1 });

    try ng.col_info[0].append(ally, .{ .size = 10, .color = 1 });

    try ng.col_info[1].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[1].append(ally, .{ .size = 1, .color = 1 });

    try ng.col_info[2].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[2].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[2].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[2].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[2].append(ally, .{ .size = 1, .color = 1 });

    try ng.col_info[3].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[3].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[3].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[3].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[3].append(ally, .{ .size = 1, .color = 1 });

    try ng.col_info[4].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[4].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[4].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[4].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[4].append(ally, .{ .size = 1, .color = 1 });

    try ng.col_info[5].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[5].append(ally, .{ .size = 1, .color = 1 });

    try ng.col_info[6].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[6].append(ally, .{ .size = 1, .color = 1 });

    try ng.col_info[7].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[7].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[7].append(ally, .{ .size = 1, .color = 1 });

    try ng.col_info[8].append(ally, .{ .size = 1, .color = 1 });
    try ng.col_info[8].append(ally, .{ .size = 1, .color = 1 });

    try ng.col_info[9].append(ally, .{ .size = 10, .color = 1 });

    const soln = &[_][10]u8{
        [10]u8{ 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 },
        [10]u8{ 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 },
        [10]u8{ 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0xff, 0x01 },
        [10]u8{ 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01 },
        [10]u8{ 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 },
        [10]u8{ 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01 },
        [10]u8{ 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 },
        [10]u8{ 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01 },
        [10]u8{ 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 },
        [10]u8{ 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 },
    };

    const nonogram_solution = try ng.solve();
    defer nonogram_solution.deinit();
    for (nonogram_solution.grid, 0..) |_, i| {
        try testing.expectEqualSlices(u8, &soln[i], nonogram_solution.grid[i]);
    }
}

test "bigger test" {
    var ng = try Nonogram.init(ally, 30, 30);
    defer ng.deinit();

    // enter clues
    {
        try ng.row_info[0].append(ally, .{ .size = 4, .color = 1 });

        try ng.row_info[1].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[1].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[1].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[1].append(ally, .{ .size = 5, .color = 1 });
        try ng.row_info[1].append(ally, .{ .size = 4, .color = 1 });

        try ng.row_info[2].append(ally, .{ .size = 5, .color = 1 });
        try ng.row_info[2].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[2].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[2].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[2].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[2].append(ally, .{ .size = 2, .color = 1 });

        try ng.row_info[3].append(ally, .{ .size = 10, .color = 1 });
        try ng.row_info[3].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[3].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[3].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[3].append(ally, .{ .size = 3, .color = 1 });

        try ng.row_info[4].append(ally, .{ .size = 6, .color = 1 });
        try ng.row_info[4].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[4].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[4].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[4].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[4].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[4].append(ally, .{ .size = 3, .color = 1 });

        try ng.row_info[5].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[5].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[5].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[5].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[5].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[5].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[5].append(ally, .{ .size = 3, .color = 1 });

        try ng.row_info[6].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[6].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[6].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[6].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[6].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[6].append(ally, .{ .size = 5, .color = 1 });

        try ng.row_info[7].append(ally, .{ .size = 10, .color = 1 });
        try ng.row_info[7].append(ally, .{ .size = 6, .color = 1 });
        try ng.row_info[7].append(ally, .{ .size = 6, .color = 1 });

        try ng.row_info[8].append(ally, .{ .size = 8, .color = 1 });
        try ng.row_info[8].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[8].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[8].append(ally, .{ .size = 3, .color = 1 });

        try ng.row_info[9].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[9].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[9].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[9].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[9].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[9].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[9].append(ally, .{ .size = 3, .color = 1 });

        try ng.row_info[10].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[10].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[10].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[10].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[10].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[10].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[10].append(ally, .{ .size = 4, .color = 1 });

        try ng.row_info[11].append(ally, .{ .size = 8, .color = 1 });
        try ng.row_info[11].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[11].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[11].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[11].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[11].append(ally, .{ .size = 2, .color = 1 });

        try ng.row_info[12].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[12].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[12].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[12].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[12].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[12].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[12].append(ally, .{ .size = 2, .color = 1 });

        try ng.row_info[13].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[13].append(ally, .{ .size = 7, .color = 1 });
        try ng.row_info[13].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[13].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[13].append(ally, .{ .size = 2, .color = 1 });

        try ng.row_info[14].append(ally, .{ .size = 8, .color = 1 });
        try ng.row_info[14].append(ally, .{ .size = 9, .color = 1 });
        try ng.row_info[14].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[14].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[14].append(ally, .{ .size = 1, .color = 1 });

        try ng.row_info[15].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[15].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[15].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[15].append(ally, .{ .size = 7, .color = 1 });
        try ng.row_info[15].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[15].append(ally, .{ .size = 5, .color = 1 });

        try ng.row_info[16].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[16].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[16].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[16].append(ally, .{ .size = 6, .color = 1 });
        try ng.row_info[16].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[16].append(ally, .{ .size = 5, .color = 1 });

        try ng.row_info[17].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[17].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[17].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[17].append(ally, .{ .size = 5, .color = 1 });

        try ng.row_info[18].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[18].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[18].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[18].append(ally, .{ .size = 5, .color = 1 });

        try ng.row_info[19].append(ally, .{ .size = 6, .color = 1 });
        try ng.row_info[19].append(ally, .{ .size = 8, .color = 1 });
        try ng.row_info[19].append(ally, .{ .size = 4, .color = 1 });

        try ng.row_info[20].append(ally, .{ .size = 6, .color = 1 });
        try ng.row_info[20].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[20].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[20].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[20].append(ally, .{ .size = 8, .color = 1 });

        try ng.row_info[21].append(ally, .{ .size = 9, .color = 1 });
        try ng.row_info[21].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[21].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[21].append(ally, .{ .size = 7, .color = 1 });

        try ng.row_info[22].append(ally, .{ .size = 7, .color = 1 });
        try ng.row_info[22].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[22].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[22].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[22].append(ally, .{ .size = 4, .color = 1 });

        try ng.row_info[23].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[23].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[23].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[23].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[23].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[23].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[23].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[23].append(ally, .{ .size = 3, .color = 1 });

        try ng.row_info[24].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[24].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[24].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[24].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[24].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[24].append(ally, .{ .size = 1, .color = 1 });

        try ng.row_info[25].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[25].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[25].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[25].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[25].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[25].append(ally, .{ .size = 4, .color = 1 });

        try ng.row_info[26].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[26].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[26].append(ally, .{ .size = 6, .color = 1 });
        try ng.row_info[26].append(ally, .{ .size = 1, .color = 1 });
        try ng.row_info[26].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[26].append(ally, .{ .size = 2, .color = 1 });

        try ng.row_info[27].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[27].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[27].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[27].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[27].append(ally, .{ .size = 4, .color = 1 });

        try ng.row_info[28].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[28].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[28].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[28].append(ally, .{ .size = 2, .color = 1 });
        try ng.row_info[28].append(ally, .{ .size = 4, .color = 1 });

        try ng.row_info[29].append(ally, .{ .size = 4, .color = 1 });
        try ng.row_info[29].append(ally, .{ .size = 3, .color = 1 });
        try ng.row_info[29].append(ally, .{ .size = 7, .color = 1 });

        try ng.col_info[0].append(ally, .{ .color = 1, .size = 7 });
        try ng.col_info[0].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[0].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[0].append(ally, .{ .color = 1, .size = 5 });

        try ng.col_info[1].append(ally, .{ .color = 1, .size = 8 });
        try ng.col_info[1].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[1].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[1].append(ally, .{ .color = 1, .size = 5 });
        try ng.col_info[1].append(ally, .{ .color = 1, .size = 3 });

        try ng.col_info[2].append(ally, .{ .color = 1, .size = 7 });
        try ng.col_info[2].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[2].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[2].append(ally, .{ .color = 1, .size = 10 });
        try ng.col_info[2].append(ally, .{ .color = 1, .size = 2 });

        try ng.col_info[3].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[3].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[3].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[3].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[3].append(ally, .{ .color = 1, .size = 7 });
        try ng.col_info[3].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[3].append(ally, .{ .color = 1, .size = 1 });

        try ng.col_info[4].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[4].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[4].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[4].append(ally, .{ .color = 1, .size = 11 });
        try ng.col_info[4].append(ally, .{ .color = 1, .size = 2 });

        try ng.col_info[5].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[5].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[5].append(ally, .{ .color = 1, .size = 6 });
        try ng.col_info[5].append(ally, .{ .color = 1, .size = 5 });
        try ng.col_info[5].append(ally, .{ .color = 1, .size = 2 });

        try ng.col_info[6].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[6].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[6].append(ally, .{ .color = 1, .size = 5 });
        try ng.col_info[6].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[6].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[6].append(ally, .{ .color = 1, .size = 1 });

        try ng.col_info[7].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[7].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[7].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[7].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[7].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[7].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[7].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[7].append(ally, .{ .color = 1, .size = 1 });

        try ng.col_info[8].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[8].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[8].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[8].append(ally, .{ .color = 1, .size = 6 });
        try ng.col_info[8].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[8].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[8].append(ally, .{ .color = 1, .size = 2 });

        try ng.col_info[9].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[9].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[9].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[9].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[9].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[9].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[9].append(ally, .{ .color = 1, .size = 1 });

        try ng.col_info[10].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[10].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[10].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[10].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[10].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[10].append(ally, .{ .color = 1, .size = 1 });

        try ng.col_info[11].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[11].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[11].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[11].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[11].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[11].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[11].append(ally, .{ .color = 1, .size = 1 });

        try ng.col_info[12].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[12].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[12].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[12].append(ally, .{ .color = 1, .size = 2 });

        try ng.col_info[13].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[13].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[13].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[13].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[13].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[13].append(ally, .{ .color = 1, .size = 4 });

        try ng.col_info[14].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[14].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[14].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[14].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[14].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[14].append(ally, .{ .color = 1, .size = 1 });

        try ng.col_info[15].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[15].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[15].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[15].append(ally, .{ .color = 1, .size = 7 });
        try ng.col_info[15].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[15].append(ally, .{ .color = 1, .size = 2 });

        try ng.col_info[16].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[16].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[16].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[16].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[16].append(ally, .{ .color = 1, .size = 1 });

        try ng.col_info[17].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[17].append(ally, .{ .color = 1, .size = 6 });
        try ng.col_info[17].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[17].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[17].append(ally, .{ .color = 1, .size = 3 });

        try ng.col_info[18].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[18].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[18].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[18].append(ally, .{ .color = 1, .size = 6 });

        try ng.col_info[19].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[19].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[19].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[19].append(ally, .{ .color = 1, .size = 9 });

        try ng.col_info[20].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[20].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[20].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[20].append(ally, .{ .color = 1, .size = 10 });

        try ng.col_info[21].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[21].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[21].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[21].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[21].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[21].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[21].append(ally, .{ .color = 1, .size = 7 });

        try ng.col_info[22].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[22].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[22].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[22].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[22].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[22].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[22].append(ally, .{ .color = 1, .size = 2 });

        try ng.col_info[23].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[23].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[23].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[23].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[23].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[23].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[23].append(ally, .{ .color = 1, .size = 2 });

        try ng.col_info[24].append(ally, .{ .color = 1, .size = 9 });
        try ng.col_info[24].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[24].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[24].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[24].append(ally, .{ .color = 1, .size = 1 });

        try ng.col_info[25].append(ally, .{ .color = 1, .size = 8 });
        try ng.col_info[25].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[25].append(ally, .{ .color = 1, .size = 5 });
        try ng.col_info[25].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[25].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[25].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[25].append(ally, .{ .color = 1, .size = 1 });

        try ng.col_info[26].append(ally, .{ .color = 1, .size = 4 });
        try ng.col_info[26].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[26].append(ally, .{ .color = 1, .size = 9 });
        try ng.col_info[26].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[26].append(ally, .{ .color = 1, .size = 3 });

        try ng.col_info[27].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[27].append(ally, .{ .color = 1, .size = 9 });
        try ng.col_info[27].append(ally, .{ .color = 1, .size = 1 });
        try ng.col_info[27].append(ally, .{ .color = 1, .size = 3 });

        try ng.col_info[28].append(ally, .{ .color = 1, .size = 3 });
        try ng.col_info[28].append(ally, .{ .color = 1, .size = 9 });
        try ng.col_info[28].append(ally, .{ .color = 1, .size = 2 });
        try ng.col_info[28].append(ally, .{ .color = 1, .size = 2 });

        try ng.col_info[29].append(ally, .{ .color = 1, .size = 15 });
        try ng.col_info[29].append(ally, .{ .color = 1, .size = 2 });
    }

    // make result data
    const soln = &[_][30]u8{
        [30]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
        [30]u8{ 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0xff, 0xff, 0xff, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
        [30]u8{ 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0x01, 0x01, 0xff, 0x01, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
        [30]u8{ 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0xff, 0xff, 0x01, 0xff, 0xff, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff },
        [30]u8{ 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0x01, 0xff, 0xff, 0x01, 0xff, 0xff, 0x01, 0xff, 0xff, 0x01, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff },
        [30]u8{ 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0x01, 0xff, 0x01, 0xff, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff },
        [30]u8{ 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0xff, 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff },
        [30]u8{ 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff },
        [30]u8{ 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff },
        [30]u8{ 0x01, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0x01, 0xff, 0xff, 0x01, 0xff, 0xff, 0x01, 0xff, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff },
        [30]u8{ 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0xff, 0x01, 0xff, 0x01, 0xff, 0xff, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff },
        [30]u8{ 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01, 0xff, 0x01, 0x01, 0xff, 0x01, 0x01, 0xff, 0xff, 0x01, 0xff, 0xff, 0x01, 0x01, 0xff },
        [30]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0xff, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0xff, 0xff, 0x01, 0x01 },
        [30]u8{ 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01 },
        [30]u8{ 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0x01 },
        [30]u8{ 0xff, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01 },
        [30]u8{ 0xff, 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01 },
        [30]u8{ 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01 },
        [30]u8{ 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01 },
        [30]u8{ 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01 },
        [30]u8{ 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0xff, 0xff, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 },
        [30]u8{ 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 },
        [30]u8{ 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01 },
        [30]u8{ 0x01, 0xff, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0xff, 0x01, 0xff, 0xff, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01 },
        [30]u8{ 0xff, 0xff, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0xff, 0xff, 0x01 },
        [30]u8{ 0x01, 0xff, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01 },
        [30]u8{ 0x01, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0x01, 0x01 },
        [30]u8{ 0x01, 0x01, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0x01, 0xff, 0xff },
        [30]u8{ 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01 },
        [30]u8{ 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 },
    };

    const ng_sol = try ng.solve();
    defer ng_sol.deinit();
    for (soln, ng_sol.grid) |*e_row, a_row| {
        try testing.expectEqualSlices(u8, e_row, a_row);
    }
}
