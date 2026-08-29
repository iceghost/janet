const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// A bit set with runtime-known size, backed by an allocated slice of usize.
///
/// This is different from `std.bit_set.Dynamic` in that the storage layout are different
/// for C compatibility.
pub const Dynamic = extern struct {
    masks: [*]MaskInt,
    /// Number of valid bits.
    bits_count: u32,
    /// Number of allocated masks.
    masks_capacity: u32,

    pub const empty: Dynamic = .{
        .masks = undefined,
        .bits_count = 0,
        .masks_capacity = 0,
    };

    /// The integer type used to represent a mask in this bit set.
    pub const MaskInt = usize;

    /// The integer type used to shift a mask in this bit set.
    pub const ShiftInt = std.math.Log2Int(MaskInt);

    pub fn deinit(self: *Dynamic, allocator: Allocator) void {
        if (self.masks_capacity > 0) allocator.free(self.masks[0..self.masks_capacity]);
        self.* = .empty;
    }

    pub fn clone(self: *const Dynamic, allocator: Allocator) Allocator.Error!Dynamic {
        var copy: Dynamic = .empty;
        try copy.resize(allocator, self.bits_count, false);
        const mask_count = masks_needed_for(self.bits_count);
        if (mask_count > 0) {
            @memcpy(copy.masks[0..mask_count], self.masks[0..mask_count]);
        }
        return copy;
    }

    /// Ensure indices below `total` are available without changing existing bits.
    pub fn reserve_total(self: *Dynamic, allocator: Allocator, total: u32) Allocator.Error!void {
        if (total > self.bits_count) try self.resize(allocator, total, false);
    }

    /// Resize the set, initializing newly added bits to `fill`.
    fn resize(self: *Dynamic, allocator: Allocator, new_count: u32, fill: bool) Allocator.Error!void {
        const old_count = self.bits_count;
        const old_mask_count = masks_needed_for(old_count);
        const new_mask_count = masks_needed_for(new_count);

        if (new_mask_count > self.masks_capacity) {
            const new_capacity = @max(new_mask_count, @max(self.masks_capacity * 2, 2));
            const masks = if (self.masks_capacity > 0)
                try allocator.realloc(self.masks[0..self.masks_capacity], new_capacity)
            else
                try allocator.alloc(MaskInt, new_capacity);
            self.masks = masks.ptr;
            self.masks_capacity = new_capacity;
        }

        if (new_mask_count > old_mask_count) {
            @memset(self.masks[old_mask_count..new_mask_count], 0);
        }

        self.bits_count = new_count;
        if (fill and new_count > old_count) {
            var index = old_count;
            while (index < new_count) : (index += 1) self.set(index);
        }

        // Keep padding clear so scans never report an out-of-range bit.
        if (new_count > 0) {
            const used_bits: ShiftInt = @truncate(new_count);
            if (used_bits != 0) {
                const padding_bits: ShiftInt = @truncate(
                    @bitSizeOf(MaskInt) - @as(usize, used_bits),
                );
                const all_bits: MaskInt = std.math.maxInt(MaskInt);
                self.masks[new_mask_count - 1] &=
                    all_bits >> padding_bits;
            }
        }
    }

    pub fn is_set(self: Dynamic, index: u32) bool {
        assert(index < self.bits_count);
        return self.masks[mask_index(index)] & mask_bit(index) != 0;
    }

    pub fn set(self: *Dynamic, index: u32) void {
        assert(index < self.bits_count);
        self.masks[mask_index(index)] |= mask_bit(index);
    }

    pub fn unset(self: *Dynamic, index: u32) void {
        assert(index < self.bits_count);
        self.masks[mask_index(index)] &= ~mask_bit(index);
    }

    /// Return the first unset bit, or the first index past the end if all are set.
    pub fn find_first_unset(self: Dynamic) u32 {
        const mask_count = masks_needed_for(self.bits_count);
        var index: u32 = 0;
        while (index < mask_count) : (index += 1) {
            const unset_mask = ~self.masks[index];
            if (unset_mask == 0) continue;
            const bit: ShiftInt = @truncate(@ctz(unset_mask));
            const result = index * @bitSizeOf(MaskInt) + bit;
            if (result < self.bits_count) return result;
        }
        return self.bits_count;
    }

    fn mask_bit(index: u32) MaskInt {
        return @as(MaskInt, 1) << @as(ShiftInt, @truncate(index));
    }

    fn mask_index(index: u32) u32 {
        return index >> @bitSizeOf(ShiftInt);
    }

    fn masks_needed_for(count: u32) u32 {
        return count / @bitSizeOf(MaskInt) +
            @intFromBool(count % @bitSizeOf(MaskInt) != 0);
    }
};

test Dynamic {
    var bits: Dynamic = .empty;
    defer bits.deinit(std.testing.allocator);

    try bits.reserve_total(std.testing.allocator, 65);
    try std.testing.expectEqual(0, bits.find_first_unset());
    bits.set(0);
    bits.set(64);
    try std.testing.expect(bits.is_set(0));
    try std.testing.expect(bits.is_set(64));
    try std.testing.expectEqual(1, bits.find_first_unset());
    bits.unset(0);
    try std.testing.expect(!bits.is_set(0));
    try bits.reserve_total(std.testing.allocator, 128);
    try std.testing.expect(!bits.is_set(127));
    bits.set(127);
    try std.testing.expect(bits.is_set(127));
    try std.testing.expectEqual(0, bits.find_first_unset());

    var copy = try bits.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expect(copy.is_set(64));
}
