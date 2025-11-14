const std = @import("std");

pub const ParameterId = enum(u8) {
    null_move_base,
    null_move_depth_divisor,
    null_move_beta_divisor,
    futility_margin_slope,
    lmr_log_scale,
};

pub const ParameterDef = struct {
    id: ParameterId,
    name: []const u8,
    min: i32,
    max: i32,
    default_value: i32,
};

pub const parameter_defs = [_]ParameterDef{
    .{ .id = .null_move_base, .name = "NullMoveBase", .min = 3, .max = 8, .default_value = 5 },
    .{ .id = .null_move_depth_divisor, .name = "NullMoveDepthDiv", .min = 2, .max = 8, .default_value = 5 },
    .{ .id = .null_move_beta_divisor, .name = "NullMoveBetaDiv", .min = 120, .max = 500, .default_value = 230 },
    .{ .id = .futility_margin_slope, .name = "FutilityMargin", .min = 40, .max = 160, .default_value = 90 },
    .{ .id = .lmr_log_scale, .name = "LMRScale", .min = 20, .max = 120, .default_value = 50 },
};

pub const SearchParams = struct {
    null_move_base: i8 = @intCast(parameter_defs[@intFromEnum(ParameterId.null_move_base)].default_value),
    null_move_depth_divisor: i8 = @intCast(parameter_defs[@intFromEnum(ParameterId.null_move_depth_divisor)].default_value),
    null_move_beta_divisor: i32 = parameter_defs[@intFromEnum(ParameterId.null_move_beta_divisor)].default_value,
    futility_margin_slope: i32 = parameter_defs[@intFromEnum(ParameterId.futility_margin_slope)].default_value,
    lmr_log_scale: i32 = parameter_defs[@intFromEnum(ParameterId.lmr_log_scale)].default_value,
};

pub const SetResult = struct {
    id: ParameterId,
    changed: bool,
    value: i32,
};

pub var params = SearchParams{};

inline fn clamp(def: ParameterDef, value: i32) i32 {
    return @max(def.min, @min(def.max, value));
}

pub fn values() SearchParams {
    return params;
}

fn applyValue(id: ParameterId, clamped_value: i32) bool {
    switch (id) {
        .null_move_base => {
            const val: i8 = @intCast(clamped_value);
            if (params.null_move_base == val) return false;
            params.null_move_base = val;
            return true;
        },
        .null_move_depth_divisor => {
            const val: i8 = @intCast(clamped_value);
            if (params.null_move_depth_divisor == val) return false;
            params.null_move_depth_divisor = val;
            return true;
        },
        .null_move_beta_divisor => {
            if (params.null_move_beta_divisor == clamped_value) return false;
            params.null_move_beta_divisor = clamped_value;
            return true;
        },
        .futility_margin_slope => {
            if (params.futility_margin_slope == clamped_value) return false;
            params.futility_margin_slope = clamped_value;
            return true;
        },
        .lmr_log_scale => {
            if (params.lmr_log_scale == clamped_value) return false;
            params.lmr_log_scale = clamped_value;
            return true;
        },
    }
}

pub fn set_by_id(id: ParameterId, value: i32) SetResult {
    const def = parameter_defs[@intFromEnum(id)];
    const clamped_value = clamp(def, value);
    const changed = applyValue(id, clamped_value);
    return SetResult{
        .id = id,
        .changed = changed,
        .value = clamped_value,
    };
}

pub fn find_by_name(name: []const u8) ?ParameterId {
    inline for (parameter_defs) |def| {
        if (std.mem.eql(u8, name, def.name)) {
            return def.id;
        }
    }
    return null;
}

pub fn set_by_name(name: []const u8, value: i32) ?SetResult {
    if (find_by_name(name)) |id| {
        return set_by_id(id, value);
    }
    return null;
}

