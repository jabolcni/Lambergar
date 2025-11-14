const std = @import("std");

pub const ParameterId = enum(u8) {
    null_move_base,
    null_move_depth_divisor,
    null_move_beta_divisor,
    futility_margin_slope,
    lmr_log_scale,
    lmr_base_offset,
    see_quiet_coeff,
    see_capture_coeff,
    history_limit_scale,
    null_move_min_depth,
    null_move_verify_phase,
    null_move_verify_depth,
    futility_prune_slope,
    razor_depth,
    razor_margin_offset,
    razor_margin_scale,
    futility_prune_depth,
    reduction_eval_scale,
    qsearch_delta_margin,
};

pub const ParameterType = enum { int, float };

pub fn type_name(ptype: ParameterType) []const u8 {
    return switch (ptype) {
        .int => "int",
        .float => "float",
    };
}

pub const ParameterDef = struct {
    id: ParameterId,
    name: []const u8,
    ptype: ParameterType = .int,
    min: i32,
    max: i32,
    default_value: i32,
    spsa_a: f32,
    spsa_c: f32,
};

pub const parameter_defs = [_]ParameterDef{
    .{ .id = .null_move_base, .name = "NullMoveBase", .min = 3, .max = 8, .default_value = 5, .spsa_a = 0.5, .spsa_c = 0.05 },
    .{ .id = .null_move_depth_divisor, .name = "NullMoveDepthDiv", .min = 2, .max = 8, .default_value = 5, .spsa_a = 0.6, .spsa_c = 0.06 },
    .{ .id = .null_move_beta_divisor, .name = "NullMoveBetaDiv", .min = 120, .max = 500, .default_value = 230, .spsa_a = 38.0, .spsa_c = 3.8 },
    .{ .id = .futility_margin_slope, .name = "FutilityMargin", .min = 40, .max = 160, .default_value = 90, .spsa_a = 7.0, .spsa_c = 0.7 },
    .{ .id = .lmr_log_scale, .name = "LMRScale", .min = 20, .max = 120, .default_value = 50, .spsa_a = 9.0, .spsa_c = 0.9 },
    .{ .id = .lmr_base_offset, .name = "LMRBaseOffset", .min = -2, .max = 3, .default_value = 0, .spsa_a = 0.4, .spsa_c = 0.04 },
    .{ .id = .see_quiet_coeff, .name = "SeeQuietCoeff", .min = 20, .max = 80, .default_value = 46, .spsa_a = 4.0, .spsa_c = 0.4 },
    .{ .id = .see_capture_coeff, .name = "SeeCaptureCoeff", .min = 4, .max = 20, .default_value = 10, .spsa_a = 1.5, .spsa_c = 0.15 },
    .{ .id = .history_limit_scale, .name = "HistoryLimitScale", .min = 60, .max = 140, .default_value = 100, .spsa_a = 6.0, .spsa_c = 0.6 },
    .{ .id = .null_move_min_depth, .name = "NullMoveMinDepth", .min = 1, .max = 4, .default_value = 2, .spsa_a = 0.3, .spsa_c = 0.03 },
    .{ .id = .null_move_verify_phase, .name = "NullMoveVerifyPhase", .min = 0, .max = 8, .default_value = 4, .spsa_a = 0.4, .spsa_c = 0.04 },
    .{ .id = .null_move_verify_depth, .name = "NullMoveVerifyDepth", .min = 3, .max = 10, .default_value = 6, .spsa_a = 0.4, .spsa_c = 0.04 },
    .{ .id = .futility_prune_slope, .name = "FutilityPruneSlope", .min = 40, .max = 140, .default_value = 85, .spsa_a = 7.0, .spsa_c = 0.7 },
    .{ .id = .razor_depth, .name = "RazorDepth", .min = 1, .max = 5, .default_value = 2, .spsa_a = 0.3, .spsa_c = 0.03 },
    .{ .id = .razor_margin_offset, .name = "RazorMarginOffset", .min = 50, .max = 250, .default_value = 150, .spsa_a = 8.0, .spsa_c = 0.8 },
    .{ .id = .razor_margin_scale, .name = "RazorMarginScale", .min = 0, .max = 150, .default_value = 75, .spsa_a = 6.0, .spsa_c = 0.6 },
    .{ .id = .futility_prune_depth, .name = "FutilityPruneDepth", .min = 4, .max = 12, .default_value = 8, .spsa_a = 0.5, .spsa_c = 0.05 },
    .{ .id = .reduction_eval_scale, .name = "ReductionEvalScale", .min = 150, .max = 600, .default_value = 350, .spsa_a = 20.0, .spsa_c = 2.0 },
    .{ .id = .qsearch_delta_margin, .name = "QDeltaMargin", .min = 200, .max = 800, .default_value = 500, .spsa_a = 20.0, .spsa_c = 2.0 },
};

pub const SearchParams = struct {
    null_move_base: i8 = @intCast(parameter_defs[@intFromEnum(ParameterId.null_move_base)].default_value),
    null_move_depth_divisor: i8 = @intCast(parameter_defs[@intFromEnum(ParameterId.null_move_depth_divisor)].default_value),
    null_move_beta_divisor: i32 = parameter_defs[@intFromEnum(ParameterId.null_move_beta_divisor)].default_value,
    futility_margin_slope: i32 = parameter_defs[@intFromEnum(ParameterId.futility_margin_slope)].default_value,
    lmr_log_scale: i32 = parameter_defs[@intFromEnum(ParameterId.lmr_log_scale)].default_value,
    lmr_base_offset: i32 = parameter_defs[@intFromEnum(ParameterId.lmr_base_offset)].default_value,
    see_quiet_coeff: i32 = parameter_defs[@intFromEnum(ParameterId.see_quiet_coeff)].default_value,
    see_capture_coeff: i32 = parameter_defs[@intFromEnum(ParameterId.see_capture_coeff)].default_value,
    history_limit_scale: i32 = parameter_defs[@intFromEnum(ParameterId.history_limit_scale)].default_value,
    null_move_min_depth: i8 = @intCast(parameter_defs[@intFromEnum(ParameterId.null_move_min_depth)].default_value),
    null_move_verify_phase: i8 = @intCast(parameter_defs[@intFromEnum(ParameterId.null_move_verify_phase)].default_value),
    null_move_verify_depth: i8 = @intCast(parameter_defs[@intFromEnum(ParameterId.null_move_verify_depth)].default_value),
    futility_prune_slope: i32 = parameter_defs[@intFromEnum(ParameterId.futility_prune_slope)].default_value,
    razor_depth: i8 = @intCast(parameter_defs[@intFromEnum(ParameterId.razor_depth)].default_value),
    razor_margin_offset: i32 = parameter_defs[@intFromEnum(ParameterId.razor_margin_offset)].default_value,
    razor_margin_scale: i32 = parameter_defs[@intFromEnum(ParameterId.razor_margin_scale)].default_value,
    futility_prune_depth: i8 = @intCast(parameter_defs[@intFromEnum(ParameterId.futility_prune_depth)].default_value),
    reduction_eval_scale: i32 = parameter_defs[@intFromEnum(ParameterId.reduction_eval_scale)].default_value,
    qsearch_delta_margin: i32 = parameter_defs[@intFromEnum(ParameterId.qsearch_delta_margin)].default_value,
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
        .lmr_base_offset => {
            if (params.lmr_base_offset == clamped_value) return false;
            params.lmr_base_offset = clamped_value;
            return true;
        },
        .see_quiet_coeff => {
            if (params.see_quiet_coeff == clamped_value) return false;
            params.see_quiet_coeff = clamped_value;
            return true;
        },
        .see_capture_coeff => {
            if (params.see_capture_coeff == clamped_value) return false;
            params.see_capture_coeff = clamped_value;
            return true;
        },
        .history_limit_scale => {
            if (params.history_limit_scale == clamped_value) return false;
            params.history_limit_scale = clamped_value;
            return true;
        },
        .null_move_min_depth => {
            const val: i8 = @intCast(clamped_value);
            if (params.null_move_min_depth == val) return false;
            params.null_move_min_depth = val;
            return true;
        },
        .null_move_verify_phase => {
            const val: i8 = @intCast(clamped_value);
            if (params.null_move_verify_phase == val) return false;
            params.null_move_verify_phase = val;
            return true;
        },
        .null_move_verify_depth => {
            const val: i8 = @intCast(clamped_value);
            if (params.null_move_verify_depth == val) return false;
            params.null_move_verify_depth = val;
            return true;
        },
        .futility_prune_slope => {
            if (params.futility_prune_slope == clamped_value) return false;
            params.futility_prune_slope = clamped_value;
            return true;
        },
        .razor_depth => {
            const val: i8 = @intCast(clamped_value);
            if (params.razor_depth == val) return false;
            params.razor_depth = val;
            return true;
        },
        .razor_margin_offset => {
            if (params.razor_margin_offset == clamped_value) return false;
            params.razor_margin_offset = clamped_value;
            return true;
        },
        .razor_margin_scale => {
            if (params.razor_margin_scale == clamped_value) return false;
            params.razor_margin_scale = clamped_value;
            return true;
        },
        .futility_prune_depth => {
            const val: i8 = @intCast(clamped_value);
            if (params.futility_prune_depth == val) return false;
            params.futility_prune_depth = val;
            return true;
        },
        .reduction_eval_scale => {
            if (params.reduction_eval_scale == clamped_value) return false;
            params.reduction_eval_scale = clamped_value;
            return true;
        },
        .qsearch_delta_margin => {
            if (params.qsearch_delta_margin == clamped_value) return false;
            params.qsearch_delta_margin = clamped_value;
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
