const std = @import("std");
const search_params = @import("search_params");

pub fn main() !void {
    const defs = search_params.parameter_defs;
    inline for (defs, 0..) |def, idx| {
        const suffix = if (idx == defs.len - 1) "" else "\n";
        std.debug.print("{s},{s},{d},{d},{d},{d:.3},{d:.3}{s}", .{
            def.name,
            search_params.type_name(def.ptype),
            def.default_value,
            def.min,
            def.max,
            def.spsa_a,
            def.spsa_c,
            suffix,
        });
    }
}
