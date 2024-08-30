const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;

pub const Block = struct { size: u32, color: u32 };

pub const SolvingState = struct { usize, usize, u32, u32 };

pub const SolutionDP = AutoHashMap(SolvingState, bool);

pub const PixelMap = AutoHashMap(u32, usize);

pub const NonogramInput = struct {
    row_qty: usize,
    col_qty: usize,
    row_inf: [][]Block,
    col_inf: [][]Block,
    ac: Allocator,
    pub fn deinit(self: *NonogramInput) void {
        for (self.col_inf) |c| self.ac.free(c);
        self.ac.free(self.col_inf);
        for (self.row_inf) |r| self.ac.free(r);
        self.ac.free(self.row_inf);
        self.* = undefined;
    }
};

pub const NonogramSolution = struct {
    grid: [][]u32,
    grid_bytes: []u32,
    ac: Allocator,
    pub fn deinit(self: *NonogramSolution) void {
        self.ac.free(self.grid_bytes);
        self.ac.free(self.grid);
    }
};
