const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const x = @import("x");

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
                try x.array_list.realloc(allocator, self.masks[0..self.masks_capacity], .{
                    .count = old_mask_count,
                    .total_new = new_capacity,
                })
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

/// A bit set with static size, which is backed by a single integer.
/// This set is good for sets with a small size, but may generate
/// inefficient code for larger sets, especially in debug mode.
pub fn Integer(comptime size: u16) type {
    return packed struct(MaskInt) {
        const Self = @This();

        // TODO: Make this a comptime field once those are fixed
        /// The number of items in this bit set
        pub const bit_length: usize = size;

        /// The integer type used to represent a mask in this bit set
        pub const MaskInt = std.meta.Int(.unsigned, size);

        /// The integer type used to shift a mask in this bit set
        pub const ShiftInt = std.math.Log2Int(MaskInt);

        /// The bit mask, as a single integer
        mask: MaskInt,

        /// A bit set with no elements present.
        pub const empty: Self = .{ .mask = 0 };

        /// A bit set with all elements present.
        pub const full: Self = .{ .mask = ~@as(MaskInt, 0) };

        /// Returns the number of bits in this bit set
        pub fn capacity(self: Self) usize {
            _ = self;
            return bit_length;
        }

        /// Returns true if the bit at the specified index
        /// is present in the set, false otherwise.
        pub fn is_set(self: Self, index: usize) bool {
            assert(index < bit_length);
            return (self.mask & mask_bit(index)) != 0;
        }

        /// Returns the total number of set bits in this bit set.
        pub fn count(self: Self) usize {
            return @popCount(self.mask);
        }

        /// Returns a new bit set with the specified bit set to `value`.
        pub fn set_value(self: Self, index: usize, value: bool) Self {
            assert(index < bit_length);
            if (MaskInt == u0) return self;
            const bit = mask_bit(index);
            const new_bit = bit & std.math.boolMask(MaskInt, value);
            return .{ .mask = (self.mask & ~bit) | new_bit };
        }

        /// Returns a new bit set with the specified bit present.
        pub fn set(self: Self, index: usize) Self {
            return self.set_value(index, true);
        }

        /// Returns a new bit set with the specified bit absent.
        pub fn unset(self: Self, index: usize) Self {
            return self.set_value(index, false);
        }

        /// Returns a new bit set with the specified bit flipped.
        pub fn toggle(self: Self, index: usize) Self {
            assert(index < bit_length);
            return .{ .mask = self.mask ^ mask_bit(index) };
        }

        /// Returns a new bit set with bits present in `toggles` flipped.
        pub fn toggle_set(self: Self, toggles: Self) Self {
            return .{ .mask = self.mask ^ toggles.mask };
        }

        /// Returns a new bit set with every bit flipped.
        pub fn toggle_all(self: Self) Self {
            return .{ .mask = ~self.mask };
        }

        /// Returns the union of two bit sets.
        pub fn union_with(self: Self, other: Self) Self {
            return .{ .mask = self.mask | other.mask };
        }

        /// Returns the intersection of two bit sets.
        pub fn intersect_with(self: Self, other: Self) Self {
            return .{ .mask = self.mask & other.mask };
        }

        /// Finds the index of the first set bit.
        /// If no bits are set, returns null.
        pub fn find_first_set(self: Self) ?usize {
            const mask = self.mask;
            if (mask == 0) return null;
            return @ctz(mask);
        }

        /// Finds the index of the last set bit.
        /// If no bits are set, returns null.
        pub fn find_last_set(self: Self) ?usize {
            const mask = self.mask;
            if (mask == 0) return null;
            return bit_length - @clz(mask) - 1;
        }

        /// Returns true iff every corresponding bit in both
        /// bit sets are the same.
        pub fn eql(self: Self, other: Self) bool {
            return bit_length == 0 or self.mask == other.mask;
        }

        /// Returns true iff the first bit set is the subset
        /// of the second one.
        pub fn subset_of(self: Self, other: Self) bool {
            return self.intersect_with(other).eql(self);
        }

        /// Returns true iff the first bit set is the superset
        /// of the second one.
        pub fn superset_of(self: Self, other: Self) bool {
            return other.subset_of(self);
        }

        /// Returns the complement bit sets. Bits in the result
        /// are set if the corresponding bits were not set.
        pub fn complement(self: Self) Self {
            return self.toggle_all();
        }

        /// Returns the xor of two bit sets. Bits in the
        /// result are set if the corresponding bits were
        /// not the same in both inputs.
        pub fn xor_with(self: Self, other: Self) Self {
            return self.toggle_set(other);
        }

        /// Returns the difference of two bit sets. Bits in
        /// the result are set if set in the first but not
        /// set in the second set.
        pub fn difference_with(self: Self, other: Self) Self {
            return self.intersect_with(other.complement());
        }

        fn mask_bit(index: usize) MaskInt {
            if (MaskInt == u0) return 0;
            return @as(MaskInt, 1) << @as(ShiftInt, @intCast(index));
        }
    };
}

pub fn Enum(comptime E: type) type {
    return packed struct(BitSet.MaskInt) {
        const Self = @This();

        /// The indexing rules for converting between keys and indices.
        pub const Indexer = std.enums.EnumIndexer(E);
        /// The element type for this set.
        pub const Key = Indexer.Key;

        /// The maximum number of items in this set.
        pub const len = Indexer.count;

        const BitSet = Integer(Indexer.count);

        bits: BitSet = .empty,

        /// Initializes the set using a struct of bools
        pub fn init(init_values: std.enums.EnumFieldStruct(E, bool, false)) Self {
            @setEvalBranchQuota(2 * @typeInfo(E).@"enum".fields.len);
            var result: Self = .{};
            if (@typeInfo(E).@"enum".is_exhaustive) {
                inline for (0..Self.len) |i| {
                    const key = comptime Indexer.keyForIndex(i);
                    const tag = @tagName(key);
                    if (@field(init_values, tag)) {
                        result.bits = result.bits.set(i);
                    }
                }
            } else {
                inline for (std.meta.fields(E)) |field| {
                    const key = @field(E, field.name);
                    if (@field(init_values, field.name)) {
                        const i = comptime Indexer.indexOf(key);
                        result.bits = result.bits.set(i);
                    }
                }
            }
            return result;
        }

        /// A set containing no keys.
        pub const empty: Self = .{ .bits = .empty };

        /// A set containing all possible keys.
        pub const full: Self = .{ .bits = .full };

        /// Returns a set containing multiple keys.
        pub fn init_many(keys: []const Key) Self {
            var s: Self = .empty;
            for (keys) |key| s = s.set(key);
            return s;
        }

        /// Returns a set containing a single key.
        pub fn init_one(key: Key) Self {
            return init_many(&[_]Key{key});
        }

        /// Returns the number of keys in the set.
        pub fn count(self: Self) usize {
            return self.bits.count();
        }

        /// Checks if a key is in the set.
        pub fn contains(self: Self, key: Key) bool {
            return self.bits.is_set(Indexer.indexOf(key));
        }

        /// Returns a new set with `key` present.
        pub fn set(self: Self, key: Key) Self {
            return .{ .bits = self.bits.set(Indexer.indexOf(key)) };
        }

        /// Returns a new set with `key` absent.
        pub fn remove(self: Self, key: Key) Self {
            return .{ .bits = self.bits.unset(Indexer.indexOf(key)) };
        }

        /// Returns a new set with `key`'s presence set to `present`.
        pub fn set_present(self: Self, key: Key, present: bool) Self {
            return .{ .bits = self.bits.set_value(Indexer.indexOf(key), present) };
        }

        /// Returns a new set with `key`'s presence toggled.
        pub fn toggle(self: Self, key: Key) Self {
            return .{ .bits = self.bits.toggle(Indexer.indexOf(key)) };
        }

        /// Returns a new set with keys in `other` toggled.
        pub fn toggle_set(self: Self, other: Self) Self {
            return .{ .bits = self.bits.toggle_set(other.bits) };
        }

        /// Returns a new set with all keys toggled.
        pub fn toggle_all(self: Self) Self {
            return .{ .bits = self.bits.toggle_all() };
        }

        /// Returns the union of two sets.
        pub fn union_with(self: Self, other: Self) Self {
            return .{ .bits = self.bits.union_with(other.bits) };
        }

        /// Returns the intersection of two sets.
        pub fn intersect_with(self: Self, other: Self) Self {
            return .{ .bits = self.bits.intersect_with(other.bits) };
        }

        /// Returns true iff both sets have the same keys.
        pub fn eql(self: Self, other: Self) bool {
            return self.bits.eql(other.bits);
        }

        /// Returns true iff all the keys in this set are
        /// in the other set. The other set may have keys
        /// not found in this set.
        pub fn subset_of(self: Self, other: Self) bool {
            return self.bits.subset_of(other.bits);
        }

        /// Returns true iff this set contains all the keys
        /// in the other set. This set may have keys not
        /// found in the other set.
        pub fn superset_of(self: Self, other: Self) bool {
            return self.bits.superset_of(other.bits);
        }

        /// Returns a set with all the keys not in this set.
        pub fn complement(self: Self) Self {
            return .{ .bits = self.bits.complement() };
        }

        /// Returns a set with keys that are in either this
        /// set or the other set, but not both.
        pub fn xor_with(self: Self, other: Self) Self {
            return .{ .bits = self.bits.xor_with(other.bits) };
        }

        /// Returns a set with keys that are in this set
        /// except for keys in the other set.
        pub fn difference_with(self: Self, other: Self) Self {
            return .{ .bits = self.bits.difference_with(other.bits) };
        }

        // /// Returns an iterator over this set, which iterates in
        // /// index order.  Modifications to the set during iteration
        // /// may or may not be observed by the iterator, but will
        // /// not invalidate it.
        // pub fn iterator(self: *const Self) Iterator {
        //     return .{ .inner = self.bits.iterator(.{}) };
        // }

        // pub const Iterator = struct {
        //     inner: BitSet.Iterator(.{}),

        //     pub fn next(self: *Iterator) ?Key {
        //         return if (self.inner.next()) |index|
        //             Indexer.keyForIndex(index)
        //         else
        //             null;
        //     }
        // };
    };
}
