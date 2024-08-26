const std = @import("std");

const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;
const AutoHashMap = std.AutoHashMap;

const LineInfo = struct { size: usize, color: u8 };

fn inSlice(comptime T: type, slice: []T, target: T) bool {
    for (slice, 0..) |_, i| {
        if (target == slice[i]) {
            return true;
        }
    }
    return false;
}

fn createLineInfo(ac: Allocator, len: usize) ![]MultiArrayList(LineInfo) {
    const res = try ac.alloc(MultiArrayList(LineInfo), len);
    for (res, 0..) |_, i| {
        res[i] = MultiArrayList(LineInfo){};
    }
    return res;
}

const Nonogram = struct {
    row_length: usize,
    col_length: usize,
    row_info: []MultiArrayList(LineInfo),
    col_info: []MultiArrayList(LineInfo),
    state: [][]u8,
    state_bytes: []u8,
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
        const state = try ac.alloc([]u8, r);
        const state_bytes = try ac.alloc(u8, r * c);
        for (state, 0..) |_, i| {
            state[i] = state_bytes[(i * c)..((i + 1) * c)];
            for (state[i], 0..) |_, j| {
                state[i][j] = 0;
            }
        }
        return .{
            .row_length = r,
            .row_info = row_inf,
            .col_length = c,
            .col_info = col_inf,
            .state = state,
            .state_bytes = state_bytes,
            .ac = ac,
        };
    }

    fn deinit(self: Self) void {
        for (self.row_info, 0..) |_, i| {
            self.row_info[i].deinit(self.ac);
        }
        self.ac.free(self.row_info);
        for (self.col_info, 0..) |_, i| {
            self.col_info[i].deinit(self.ac);
        }
        self.ac.free(self.col_info);

        self.ac.free(self.state_bytes);

        self.ac.free(self.state);
    }

    pub const LineType = enum { ROW, COL };
    fn addLineData(self: Self, lt: LineType, idx: usize, data: MultiArrayList(LineInfo)) !void {
        const line_data = switch (lt) {
            .ROW => .{ self.row_length, self.col_length, self.row_info },
            .COL => .{ self.col_length, self.row_length, self.col_info },
            else => unreachable,
        };
        if (idx >= line_data[0]) {
            return NonogramErrors.InvalidIndex;
        }
        if (line_data[2][idx].len != 0) {
            return NonogramErrors.LineDataAlreadyExist;
        }
        var pixel_count: usize = 0;
        for (0..data.len) |i| {
            const sz = data.slice().items(.size)[i];
            const cl = data.slice().items(.color)[i];
            try line_data[2][idx].append(ally, .{
                .size = sz,
                .color = cl,
            });
            pixel_count += sz;
            if ((i > 0) and (cl == data.slice().items(.color)[i - 1])) {
                pixel_count += 1;
            }
        }
        if (pixel_count > line_data[1]) {
            return NonogramErrors.InvalidLineData;
        }
    }

    fn updateLineData(self: Self, lt: LineType, idx: usize, data: MultiArrayList(LineInfo)) !void {
        const line_data = switch (lt) {
            .ROW => .{ self.row_length, self.row_info },
            .COL => .{ self.col_length, self.col_info },
            else => unreachable,
        };
        if (idx >= line_data[0]) {
            return NonogramErrors.InvalidIndex;
        }
        line_data[1][idx].shrinkAndFree(self.ac, 0);
        try self.addLineData(lt, idx, data);
    }

    fn solveLine(_: Self, _: LineType, _: usize) !bool {
        // TODO: implement line solver
        return true;
    }

    fn validate(self: *const Self) !bool {
        var pixel_count = AutoHashMap(u8, usize).init(self.ac);
        defer pixel_count.deinit();
        for (self.row_info, 0..) |_, i| {
            for (self.row_info[i].items(.color), self.row_info[i].items(.size)) |cl, sz| {
                if (pixel_count.get(cl) == null) {
                    try pixel_count.put(cl, 0);
                }
                pixel_count.getPtr(cl).?.* += sz;
            }
        }
        for (self.col_info, 0..) |_, i| {
            for (self.col_info[i].items(.color), self.col_info[i].items(.size)) |cl, sz| {
                const aa = pixel_count.getPtr(cl);
                if ((aa == null) or (aa.?.* < sz)) {
                    return false;
                }
                aa.?.* -= sz;
                if (aa.?.* == 0) {
                    _ = pixel_count.remove(cl);
                }
            }
        }
        return pixel_count.count() == 0;
    }

    fn solve(self: Self) !void {
        if (!(try self.validate())) {
            return NonogramErrors.PixelCountMismatch;
        }
        while (true) {
            var res: bool = false;
            for (self.row_info, 0..) |_, i| {
                res = res or try self.solveLine(.ROW, i);
            }
            for (self.col_info, 0..) |_, i| {
                res = res or try self.solveLine(.COL, i);
            }
            if (!res) {
                return NonogramErrors.Unsolvable;
            }
            res = for (self.state, 0..) |_, i| {
                if (inSlice(u8, self.state[i], 0)) {
                    break true;
                }
            } else false;
            if (!res) {
                break;
            }
        }
    }
};

const testing = std.testing;
const ally = testing.allocator;

test "line create test" {
    const aaa = try createLineInfo(ally, 10);
    defer ally.free(aaa);

    for (aaa, 0..) |_, i| {
        defer aaa[i].deinit(ally);
    }
}

test "base test" {
    const nonogram = try Nonogram.init(ally, 2, 2);
    defer nonogram.deinit();
    try testing.expectEqual(nonogram.row_length, 2);
    try testing.expectEqual(nonogram.col_length, 2);
    var line_data = MultiArrayList(LineInfo){};
    defer line_data.deinit(ally);
}
