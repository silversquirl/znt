const std = @import("std");

/// Globally unique entity identifier, usable as a UUIDv4
pub const EntityId = u128;

pub const EidHash = struct {
    // We can use this incredibly fast hash function because our bits are already randomly distributed
    pub fn hash(_: EidHash, eid: EntityId) u64 {
        return @truncate(u64, eid) ^ @truncate(u64, eid >> 64);
    }
    pub fn eql(_: EidHash, a: EntityId, b: EntityId) bool {
        return a == b;
    }
};

pub const SceneOptions = struct {
    RandomSource: type = std.rand.Xoroshiro128,
};

pub fn Scene(comptime EntityType: type, comptime opts: SceneOptions) type {
    return struct {
        allocator: *std.mem.Allocator,
        rng: opts.RandomSource,
        id_map: IdMap = .{},
        entities: DataStore(EntityI) = .{},
        components: ComponentStores = .{},

        pub const Entity = EntityType;
        pub const Component = std.meta.FieldEnum(Entity);

        const IdMap = std.HashMapUnmanaged(EntityId, Addr, EidHash, 80);

        const component_count = std.meta.fields(Entity).len;
        const EntityI = struct {
            eid: EntityId,
            indices: [component_count]Addr,
        };
        const ComponentStores = blk: {
            var fields = std.meta.fields(Entity)[0..component_count].*;
            for (fields) |*field, i| {
                field.name = std.fmt.comptimePrint("{d}", .{i});
                field.field_type = DataStore(EntityComponent(field.field_type));
                const default_value: ?field.field_type = field.field_type{};
                field.default_value = default_value;
            }
            break :blk @Type(.{ .Struct = .{
                .is_tuple = true,
                .layout = .Auto,
                .decls = &.{},
                .fields = &fields,
            } });
        };
        fn EntityComponent(comptime T: type) type {
            return struct {
                entity: Addr,
                component: T,
            };
        }

        pub const OptionalEntity = blk: {
            var fields = [_]std.builtin.TypeInfo.StructField{undefined} ** (component_count + 1);

            const default_id: ?EntityId = null;
            fields[0] = .{
                .name = "id",
                .field_type = ?EntityId,
                .default_value = default_id,
                .is_comptime = false,
                .alignment = @alignOf(?EntityId),
            };

            for (std.meta.fields(Entity)) |field, i| {
                fields[i + 1] = .{
                    .name = field.name,
                    .field_type = ?field.field_type,
                    .default_value = @as(??field.field_type, @as(?field.field_type, null)),
                    .is_comptime = false,
                    .alignment = @alignOf(?field.field_type),
                };
            }

            break :blk @Type(.{ .Struct = .{
                .is_tuple = false,
                .layout = .Auto,
                .decls = &.{},
                .fields = &fields,
            } });
        };

        pub fn PartialEntity(comptime components: []const Component) type {
            var fields = [_]std.builtin.TypeInfo.StructField{undefined} ** (components.len + 1);

            fields[0] = .{
                .name = "id",
                .field_type = EntityId,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(EntityId),
            };

            for (components) |comp, i| {
                var field = std.meta.fieldInfo(Entity, comp);
                fields[i + 1] = .{
                    .name = field.name,
                    .field_type = *field.field_type,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(*field.field_type),
                };
            }

            return @Type(.{ .Struct = .{
                .is_tuple = false,
                .layout = .Auto,
                .decls = &.{},
                .fields = &fields,
            } });
        }

        const Self = @This();

        pub fn init(allocator: *std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .rng = opts.RandomSource.init(std.crypto.random.int(u64)),
            };
        }

        pub fn deinit(self: *Self) void {
            self.id_map.deinit(self.allocator);
            self.entities.deinit(self.allocator);
            comptime var i = 0;
            inline while (i < self.components.len) : (i += 1) {
                self.components[i].deinit(self.allocator);
            }
        }

        // FIXME: cleanup properly on error
        pub fn add(self: *Self, entity: OptionalEntity) !EntityId {
            const addr = try self.entities.add(self.allocator, .{
                .eid = entity.id orelse self.genEid(),
                .indices = [_]Addr{invalid_addr} ** component_count,
            });
            var ei = self.entities.get(addr).?;

            inline for (comptime std.meta.fieldNames(OptionalEntity)[1..]) |name, i| {
                if (@field(entity, name)) |value| {
                    ei.indices[i] = try self.components[i].add(self.allocator, .{
                        .entity = addr,
                        .component = value,
                    });
                }
            }

            const eid = ei.eid; // HACK: Workaround for stage1 bug
            try self.id_map.put(self.allocator, eid, addr);
            return eid;
        }

        fn genEid(self: *Self) EntityId {
            var id = self.rng.random.int(EntityId);
            // Set UUID variant and version
            id &= ~(@as(EntityId, 0xc0_00_f0) << (6 * 8));
            id |= @as(EntityId, 0x80_00_40) << (6 * 8);
            return id;
        }

        /// If the entity exists, it must have all of the specified components
        pub fn get(self: Self, comptime components: []const Component, eid: EntityId) ?PartialEntity(components) {
            const addr = self.id_map.get(eid) orelse return null;

            // Retrieve all components
            var entity: PartialEntity(components) = undefined;
            const indices = self.entities.get(addr).?.indices;
            inline for (components) |comp| {
                const field = std.meta.fieldInfo(Entity, comp);
                @field(entity, field.name) = self.getComponent(comp, indices).?;
            }

            entity.id = eid;
            return entity;
        }

        /// If the entity exists, it must have the specified component
        pub fn getOne(self: Self, comptime comp: Component, eid: EntityId) ?*std.meta.fieldInfo(Entity, comp).field_type {
            const addr = self.id_map.get(eid) orelse return null;
            const indices = self.entities.get(addr).?.indices;
            return self.getComponent(comp, indices).?;
        }

        pub fn componentByType(comptime T: type) Component {
            var comp_opt: ?Component = null;
            inline for (std.meta.fields(Entity)) |field| {
                if (field.field_type == T) {
                    if (comp_opt == null) {
                        comp_opt = @field(Component, field.name);
                    } else {
                        @compileError("More than one component with type " ++ @typeName(T));
                    }
                }
            }

            if (comp_opt) |comp| {
                return comp;
            } else {
                @compileError("No component with type " ++ @typeName(T));
            }
        }

        fn getComponent(self: Self, comptime comp: Component, indices: [component_count]Addr) ?*std.meta.fieldInfo(Entity, comp).field_type {
            if (self.components[@enumToInt(comp)].get(indices[@enumToInt(comp)])) |res| {
                return &res.component;
            } else {
                return null;
            }
        }

        /// Returns the number of entities with the specified component
        pub fn count(self: Self, comptime comp: Component) u32 {
            return self.components[@enumToInt(comp)].count;
        }

        /// The component specified first will be the one iterated through. If you know
        /// which component is likely to have the least entries, specify that one first.
        pub fn iter(self: *const Self, comptime components: []const Component) //
        if (components.len == 0) Iterator else ComponentIterator(components) {
            if (components.len == 0) {
                return .{ .it = self.entities.iter() };
            } else {
                return .{
                    .scene = self,
                    .it = self.components[@enumToInt(components[0])].iter(),
                };
            }
        }

        pub const Iterator = struct {
            it: DataStore(EntityI),
            pub fn next(self: *Iterator) ?PartialEntity(&.{}) {
                const ei = self.it.next() orelse return null;
                return PartialEntity(&.{}){ .id = ei.eid };
            }
        };

        pub fn ComponentIterator(comptime required_components: []const Component) type {
            return struct {
                scene: *const Self,
                it: std.meta.fields(ComponentStores)[@enumToInt(required_components[0])].field_type.Iterator,

                const Iter = @This();

                pub fn next(self: *Iter) ?PartialEntity(required_components) {
                    var entity: PartialEntity(required_components) = undefined;
                    search: while (true) {
                        const res = self.it.next() orelse return null;
                        const ei = self.scene.entities.get(res.entity).?;

                        // Retrieve all components
                        inline for (required_components) |comp_id, i| {
                            const comp = if (i == 0)
                                &res.component
                            else
                                self.scene.getComponent(comp_id, ei.indices) orelse
                                    // If we're missing a component, skip this entity and keep looking
                                    continue :search;
                            const field = std.meta.fieldInfo(Entity, comp_id);
                            @field(entity, field.name) = comp;
                        }

                        // Set the entity ID and return
                        entity.id = ei.eid;
                        return entity;
                    }
                }
            };
        }
    };
}

// An index into a DataStore. Unique only within that DataStore, and may be reused after the corresponding entry is deleted
// The maximum address is invalid, and can be used to represent a missing entry
const Addr = u32;
const invalid_addr = std.math.maxInt(Addr);

// This datastructure stores entries of a given type, addressed by Addr
// Insertion order is not maintained, and addresses may be reused
fn DataStore(comptime T: type) type {
    return struct {
        entries: std.ArrayListUnmanaged(Entry) = .{},
        count: Addr = 0, // Number of allocated entries
        free: Addr = invalid_addr, // Address of the first free entry, if any

        const Self = @This();
        const Entry = union(enum) {
            alloced: T, // The value, if this entry is allocated
            free: Addr, // The next free entry, if this entry is unallocated
        };

        pub fn deinit(self: *Self, allocator: *std.mem.Allocator) void {
            self.entries.deinit(allocator);
        }

        // HACK: noinline is a workaround for a compiler bug - see comment on "6 components" test
        pub noinline fn add(self: *Self, allocator: *std.mem.Allocator, value: T) std.mem.Allocator.Error!Addr {
            if (self.free != invalid_addr) {
                const addr = self.free;
                self.free = self.entries.items[addr].free;
                self.entries.items[addr] = .{ .alloced = value };
                self.count += 1;
                return addr;
            }

            const addr = self.entries.items.len;
            if (addr >= invalid_addr) return error.OutOfMemory;
            try self.entries.append(allocator, .{ .alloced = value });
            self.count += 1;
            return @intCast(Addr, addr);
        }

        pub fn get(self: Self, addr: Addr) ?*T {
            if (addr >= self.entries.items.len) return null;
            return switch (self.entries.items[addr]) {
                .alloced => |*value| value,
                .free => null,
            };
        }

        /// addr must be valid
        pub fn del(self: *Self, addr: Addr) void {
            std.debug.assert(self.entries[addr] == .alloced);
            self.entries[addr] = .{ .free = self.free };
            self.free = addr;
            self.count -= 1;
        }

        pub fn iter(self: *const Self) Iterator {
            return .{ .store = self };
        }

        pub const Iterator = struct {
            store: *const Self,
            idx: Addr = 0,

            pub fn next(self: *Iterator) ?*T {
                while (self.idx < self.store.entries.items.len) {
                    self.idx += 1;
                    if (self.store.get(self.idx - 1)) |value| {
                        return value;
                    }
                }
                return null;
            }
        };
    };
}

test "create scene" {
    var scene = TestScene.init(std.testing.allocator);
    defer scene.deinit();
}

test "add/get entities" {
    var scene = TestScene.init(std.testing.allocator);
    defer scene.deinit();

    const e1 = try scene.add(.{});
    const e2 = try scene.add(.{ .x = .{} });
    const e3 = try scene.add(.{ .y = .{ .a = 7 } });
    const e4 = try scene.add(.{ .z = 10 });

    try std.testing.expect(scene.get(&.{}, e1) != null);
    try std.testing.expect(scene.get(&.{.x}, e2) != null);
    try std.testing.expectEqual(@as(i32, 7), scene.get(&.{.y}, e3).?.y.a);
    try std.testing.expectEqual(@as(i32, 10), scene.get(&.{.z}, e4).?.z.*);
}

test "get multiple components" {
    var scene = TestScene.init(std.testing.allocator);
    defer scene.deinit();

    const id = try scene.add(.{ .x = .{}, .y = .{ .a = 7 }, .z = 10 });
    const ent = scene.get(&.{ .x, .y, .z }, id) orelse return error.UnexpectedResult;
    try std.testing.expectEqual(@as(i32, 7), ent.y.a);
    try std.testing.expectEqual(@as(i32, 10), ent.z.*);
}

test "iterate entities" {
    var scene = TestScene.init(std.testing.allocator);
    defer scene.deinit();

    _ = try scene.add(.{});
    _ = try scene.add(.{ .x = .{} });
    _ = try scene.add(.{ .y = .{ .a = 7 } });
    _ = try scene.add(.{ .z = 10 });
    _ = try scene.add(.{ .y = .{ .a = 3 } });
    _ = try scene.add(.{ .z = 11, .x = .{} });
    _ = try scene.add(.{ .z = 12, .y = .{ .a = 3 } });
    _ = try scene.add(.{ .z = 13 });

    var n: i32 = 10;
    var it = scene.iter(&.{.z});
    while (it.next()) |ent| {
        try std.testing.expectEqual(n, ent.z.*);
        n += 1;
    }
}

test "iterate multiple components" {
    var scene = TestScene.init(std.testing.allocator);
    defer scene.deinit();

    _ = try scene.add(.{});
    _ = try scene.add(.{ .x = .{} });
    _ = try scene.add(.{ .y = .{ .a = 7 } });
    _ = try scene.add(.{ .z = 10 });
    _ = try scene.add(.{ .y = .{ .a = 3 } });
    _ = try scene.add(.{ .z = 11, .x = .{}, .y = .{ .a = 3 } });
    _ = try scene.add(.{ .z = 12, .y = .{ .a = 3 } });
    _ = try scene.add(.{ .z = 13 });
    _ = try scene.add(.{ .z = 12, .x = .{}, .y = .{ .a = 4 } });
    _ = try scene.add(.{ .z = 13 });
    _ = try scene.add(.{ .z = 13, .x = .{}, .y = .{ .a = 5 } });
    _ = try scene.add(.{ .z = 12, .y = .{ .a = 3 } });
    _ = try scene.add(.{ .z = 14, .x = .{}, .y = .{ .a = 6 } });

    var y: i32 = 3;
    var z: i32 = 11;
    var it = scene.iter(&.{ .z, .y, .x });
    while (it.next()) |ent| {
        try std.testing.expectEqual(y, ent.y.a);
        try std.testing.expectEqual(z, ent.z.*);
        y += 1;
        z += 1;
    }
}

const TestScene = Scene(struct {
    x: struct {},
    y: struct { a: i32 },
    z: i32,
}, .{});

// This tests a bug where between 4 and 7 components (inclusive) causes a
// segfault after the first add, iff compiling in a release mode
test "6 components" {
    const BigScene = Scene(struct {
        a: void,
        b: void,
        c: void,
        d: void,
        e: void,
        f: void,
    }, .{});
    var scene = BigScene.init(std.testing.allocator);
    defer scene.deinit();

    _ = try scene.add(.{});
    _ = try scene.add(.{});
    _ = try scene.add(.{});
    _ = try scene.add(.{});
}
