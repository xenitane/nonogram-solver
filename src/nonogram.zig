const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;

const Block = types.Block;
const NonogramInput = types.NonogramInput;
const NonogramSolution = types.NonogramSolution;
const SolutionState = types.SolvingState;
const SolutionDP = types.SolutionDP;
const PixelMap = types.PixelMap;

const NonogramErrors = errors.NonogramErrors;

const white: u32 = 0xffffffff;

pub fn solve(ngi: *const NonogramInput) !NonogramSolution {
    if (!(try validate(ngi))) return NonogramErrors.PixelCountMismatch;

    const state = try ngi.ac.alloc([]u32, ngi.row_qty);
    const state_bytes = try ngi.ac.alloc(u32, ngi.row_qty * ngi.col_qty);
    const state_marker = try ngi.ac.alloc(u32, @max(ngi.row_qty, ngi.col_qty));

    errdefer {
        ngi.ac.free(state_bytes);
        ngi.ac.free(state);
    }
    defer ngi.ac.free(state_marker);

    @memset(state_bytes, 0);
    for (state, 0..) |_, i| state[i] = state_bytes[(i * ngi.col_qty)..((i + 1) * ngi.col_qty)];

    var ii: u32 = 0;
    while (true) : (ii = ii + 1) {
        var res: bool = false;
        for (ngi.row_inf, 0..) |_, i| {
            @memcpy(state_marker[0..ngi.col_qty], state[i]);
            const is_line_modified = try solveLine(ngi.ac, state_marker[0..ngi.col_qty], ngi.row_inf[i]);
            if (is_line_modified) {
                res = true;
                @memcpy(state[i], state_marker[0..ngi.col_qty]);
            }
        }
        for (ngi.col_inf, 0..) |_, i| {
            for (0..ngi.row_qty) |j| state_marker[j] = state[j][i];
            const is_line_modified = try solveLine(ngi.ac, state_marker[0..ngi.row_qty], ngi.col_inf[i]);
            if (is_line_modified) {
                res = true;
                for (0..ngi.row_qty) |j| state[j][i] = state_marker[j];
            }
        }
        if (!res) return NonogramErrors.Unsolvable;

        if (std.mem.indexOfScalar(u32, state_bytes, 0) == null) break;

        if (ii == state_bytes.len) return NonogramErrors.Unsolvable;
    }
    return .{ .grid = state, .grid_bytes = state_bytes, .ac = ngi.ac };
}

fn validate(ngi: *const NonogramInput) !bool {
    var pixel_frq = PixelMap.init(ngi.ac);
    defer pixel_frq.deinit();
    for (ngi.row_inf) |row| {
        if (0 == row.len) continue;

        var pixel_count: usize = 0;
        var prev_block = row[0];

        for (row) |block| {
            const aa = pixel_frq.getPtr(block.color) orelse blk: {
                try pixel_frq.put(block.color, 0);
                break :blk pixel_frq.getPtr(block.color).?;
            };

            aa.* += block.size;
            pixel_count += block.size;

            if (block.color != prev_block.color) pixel_count += 1;

            prev_block = block;
        }

        if (pixel_count > ngi.col_qty) return NonogramErrors.InvalidLineData;
    }
    for (ngi.col_inf) |col| {
        if (0 == col.len) continue;

        var pixel_count: usize = 0;
        var prev_block = col[0];

        for (col) |block| {
            const frq = pixel_frq.getPtr(block.color) orelse return false;

            if (frq.* < block.size) return false;

            frq.* -= block.size;
            pixel_count += block.size;

            if (frq.* == 0) _ = pixel_frq.remove(block.color);

            if (block.color != prev_block.color) pixel_count += 1;

            prev_block = block;
        }

        if (pixel_count > ngi.row_qty) return NonogramErrors.InvalidLineData;
    }
    return pixel_frq.count() == 0;
}

// don't forget to free memory of the solution

fn solveLine(ac: Allocator, state: []u32, line_info: []const Block) !bool {
    const iterable_state_res = try ac.alloc(u32, state.len);
    const iterable_state_itr = try ac.alloc(u32, state.len);
    defer ac.free(iterable_state_itr);
    defer ac.free(iterable_state_res);

    @memset(iterable_state_res, 0);
    @memset(iterable_state_itr, 0);

    var dynamic_data: SolutionDP = SolutionDP.init(ac);
    defer dynamic_data.deinit();

    var tried = false;

    _ = (try solveLineMain(&dynamic_data, state, .{ iterable_state_res, iterable_state_itr }, line_info, .{ 0, 0, white, 0 }, &tried));
    if (line_info.len > 0) _ = (try solveLineMain(&dynamic_data, state, .{ iterable_state_res, iterable_state_itr }, line_info, .{ 0, 0, line_info[0].color, 1 }, &tried));

    if (std.mem.eql(u32, state, iterable_state_res)) return false;

    @memcpy(state, iterable_state_res);
    return true;
}

fn solveLineMain(dynamic_data: *SolutionDP, original_state: []const u32, iterable_state: struct { []u32, []u32 }, line_info: []const Block, state: SolutionState, tried: *bool) !bool {
    const idx = state[0];
    const block_idx = state[1];
    const to_fill = state[2];
    const cells_filled = state[3];
    if ((idx > original_state.len) or (block_idx > line_info.len) or (cells_filled > original_state.len)) return false;

    const res = dynamic_data.get(.{ idx, block_idx, cells_filled, to_fill }) orelse blk: {
        const res = if (idx == original_state.len) blk0: {
            const res = if ((block_idx == line_info.len) and (cells_filled == 0)) true else false;
            if (res and !tried.*) {
                tried.* = true;
                @memcpy(iterable_state[0], iterable_state[1]);
            }
            break :blk0 res;
        } else if (block_idx == line_info.len) switch (original_state[idx]) {
            0x00, white => blk0: {
                iterable_state[1][idx] = white;
                defer iterable_state[1][idx] = 0;
                break :blk0 try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx, white, 0 }, tried);
            },
            else => false,
        } else switch (original_state[idx]) {
            0x00 => blk0: {
                iterable_state[1][idx] = to_fill;
                defer iterable_state[1][idx] = 0;

                break :blk0 if (to_fill == white) blk1: {
                    const res_put_wall_next = try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx, white, 0 }, tried);
                    const res_start_block_next = try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx, line_info[block_idx].color, 1 }, tried);
                    break :blk1 res_put_wall_next or res_start_block_next;
                } else if (to_fill == line_info[block_idx].color) if (cells_filled == line_info[block_idx].size) blk1: {
                    const res_put_wall_next = try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx + 1, white, 0 }, tried);
                    const res_start_block_next_if_possible = if ((block_idx + 1 != line_info.len) and (to_fill != line_info[block_idx + 1].color)) try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx + 1, line_info[block_idx + 1].color, 1 }, tried) else false;
                    break :blk1 res_put_wall_next or res_start_block_next_if_possible;
                } else try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx, to_fill, cells_filled + 1 }, tried) else false;
            },
            white => blk0: {
                if (to_fill != white) break :blk0 false;

                iterable_state[1][idx] = to_fill;
                defer iterable_state[1][idx] = 0;

                const res_put_wall_next = try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx, 0xff, 0 }, tried);
                const res_start_block_next = try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx, line_info[block_idx].color, 1 }, tried);
                break :blk0 res_put_wall_next or res_start_block_next;
            },
            else => blk0: {
                if ((to_fill != line_info[block_idx].color) or (to_fill != original_state[idx])) break :blk0 false;

                iterable_state[1][idx] = to_fill;
                defer iterable_state[1][idx] = 0;

                break :blk0 if (line_info[block_idx].size == cells_filled) blk1: {
                    const res_put_wall_next = try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx + 1, white, 0 }, tried);
                    const res_start_block_next_if_possible = if ((block_idx + 1 != line_info.len) and (to_fill != line_info[block_idx + 1].color)) try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx + 1, line_info[block_idx + 1].color, 1 }, tried) else false;
                    break :blk1 res_put_wall_next or res_start_block_next_if_possible;
                } else try solveLineMain(dynamic_data, original_state, iterable_state, line_info, .{ idx + 1, block_idx, to_fill, cells_filled + 1 }, tried);
            },
        };
        try dynamic_data.put(.{ idx, block_idx, cells_filled, to_fill }, res);
        break :blk res;
    };
    if (res and (idx > 0) and (iterable_state[0][idx - 1] != iterable_state[1][idx - 1])) {
        iterable_state[0][idx - 1] = 0;
    }
    return res;
}

const testing = std.testing;
const ally = testing.allocator;

test solveLineMain {
    const mem = try ally.alloc(u32, 5);
    defer ally.free(mem);
    @memset(mem, 0);

    const soln = try solveLine(ally, mem, &[_]Block{ Block{ .size = 3, .color = 1 }, Block{ .size = 1, .color = 1 } });
    try testing.expectEqual(true, soln);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 1, 1, white, 1 }, mem);
}
