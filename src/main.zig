const std = @import("std");
const nonogram = @import("nonogram.zig");
const serializer = @import("serializer.zig");

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    const args = std.os.argv;
    for (args, 0..) |arg, i| {
        try stdout.print("{d:0>2}: {s}\n", .{ i, arg });
    }
    try bw.flush();
}

const testing = std.testing;
const ally = testing.allocator;

test "wtf" {
    const file_path = "./test-data/a.txt";
    var nonogram_in = try serializer.serializeFileFromPath(ally, file_path);
    defer nonogram_in.deinit();
    var nonogram_sol = try nonogram.solve(&nonogram_in);
    defer nonogram_sol.deinit();

    try testing.expectEqualSlices(u32, &[_]u32{ 0xffffffff, 0xff, 0xff, 0xff }, nonogram_sol.grid_bytes);
}
