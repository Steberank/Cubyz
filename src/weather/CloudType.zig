//! A cloud type describes the density field of one kind of cloud as a stack of
//! noise layers, plus the weather and shading parameters derived from it.
//!
//! Types are loaded from `assets/cubyz/cloud_types/*.zig.zon`. The client also
//! uploads them to the GPU as two flat buffers: all noise layers of all types
//! concatenated, and one `GpuLayerGroup` per type pointing into that array. The
//! server needs the same registry to decide what weather a formation brings, so
//! this must not depend on the renderer.

const std = @import("std");

const main = @import("main");
const ZonElement = main.ZonElement;

const CloudType = @This();

/// Cloud space units are `main.weather.cloudScale` blocks wide. Layer heights
/// are measured upwards from the cloud layer, along Z.
pub const NoiseLayer = struct {
	height: f32 = 32,
	heightOffset: f32 = 0,
	scaleX: f32 = 30,
	scaleY: f32 = 30,
	scaleZ: f32 = 10,
	valueOffset: f32 = -0.5,
	valueScale: f32 = 1,
	fadeDistance: f32 = 10,
};

pub const Weather = enum {
	none,
	rain,
	thunderstorm,

	pub fn includesThunder(self: Weather) bool {
		return self == .thunderstorm;
	}
};

/// Controls how regions of this type are placed in the world. Only used by the
/// region spawner, not by the mesh generator.
pub const Spawning = struct {
	weight: f32 = 1,
	/// Regions with a higher order weight win where two regions overlap.
	orderWeight: f32 = 500,
	/// Radius of the formation, in blocks.
	minRadius: f32 = 4000,
	maxRadius: f32 = 10000,
	/// How fast the formation drifts, in blocks per second.
	minSpeed: f32 = 16,
	maxSpeed: f32 = 32,
	/// How much the formation is squashed along one axis. 1 is a circle.
	minStretch: f32 = 1,
	maxStretch: f32 = 1,
	/// Whether the formation heads for the player instead of drifting past.
	movesTowardsPlayer: bool = false,
};

pub const maxNoiseLayers = 4;
pub const maxCloudTypes = 64;

id: []const u8,
layers: []NoiseLayer,
weather: Weather,
storminess: f32,
stormStart: f32,
stormFadeDistance: f32,
transparencyFade: f32,
spawning: Spawning,

/// Layout of `NoiseLayer` in `cube_mesh.comp`. Field order must match exactly.
pub const GpuNoiseLayer = extern struct {
	height: f32,
	valueOffset: f32,
	scaleX: f32,
	scaleY: f32,
	scaleZ: f32,
	fadeDistance: f32,
	heightOffset: f32,
	valueScale: f32,
};

/// Layout of `LayerGroup` in `cube_mesh.comp`. Field order must match exactly.
pub const GpuLayerGroup = extern struct {
	startIndex: i32,
	endIndex: i32,
	storminess: f32,
	stormStart: f32,
	stormFadeDistance: f32,
	transparencyFade: f32,
};

fn parseLayer(zon: ZonElement) NoiseLayer {
	var layer: NoiseLayer = .{};
	inline for (@typeInfo(NoiseLayer).@"struct".fields) |field| {
		@field(layer, field.name) = zon.get(f32, field.name) orelse @field(layer, field.name);
	}
	return layer;
}

fn parseSpawning(zon: ZonElement) Spawning {
	var spawning: Spawning = .{};
	inline for (@typeInfo(Spawning).@"struct".fields) |field| {
		@field(spawning, field.name) = zon.get(field.type, field.name) orelse @field(spawning, field.name);
	}
	if (spawning.maxRadius < spawning.minRadius) spawning.maxRadius = spawning.minRadius;
	if (spawning.maxSpeed < spawning.minSpeed) spawning.maxSpeed = spawning.minSpeed;
	if (spawning.maxStretch < spawning.minStretch) spawning.maxStretch = spawning.minStretch;
	return spawning;
}

pub fn fromZon(allocator: main.heap.NeverFailingAllocator, id: []const u8, zon: ZonElement) CloudType {
	const layersZon = zon.getChild("noiseLayers");
	// A single layer may be written directly instead of as a one element list.
	const layerElements = if (layersZon == .array) layersZon.toSlice() else &[_]ZonElement{layersZon};

	const layerCount = @min(layerElements.len, maxNoiseLayers);
	if (layerElements.len > maxNoiseLayers) {
		std.log.err("Cloud type {s} has {} noise layers, only {} are supported.", .{id, layerElements.len, maxNoiseLayers});
	}

	const layers = allocator.alloc(NoiseLayer, layerCount);
	for (layers, layerElements[0..layerCount]) |*layer, element| {
		layer.* = parseLayer(element);
		if (layer.fadeDistance <= 0) layer.fadeDistance = 1;
		if (layer.scaleX == 0 or layer.scaleY == 0 or layer.scaleZ == 0) {
			std.log.err("Cloud type {s} has a noise layer with a zero scale, clamping.", .{id});
			layer.scaleX = @max(layer.scaleX, 0.1);
			layer.scaleY = @max(layer.scaleY, 0.1);
			layer.scaleZ = @max(layer.scaleZ, 0.1);
		}
	}

	return .{
		.id = allocator.dupe(u8, id),
		.layers = layers,
		.weather = zon.get(Weather, "weather") orelse .none,
		.storminess = std.math.clamp(zon.get(f32, "storminess") orelse 0, 0, 1),
		.stormStart = zon.get(f32, "stormStart") orelse 0,
		.stormFadeDistance = @max(zon.get(f32, "stormFadeDistance") orelse 32, 0.001),
		.transparencyFade = std.math.clamp(zon.get(f32, "transparencyFade") orelse 0, 0, 32),
		.spawning = parseSpawning(zon.getChild("spawning")),
	};
}

pub fn deinit(self: CloudType, allocator: main.heap.NeverFailingAllocator) void {
	allocator.free(self.id);
	allocator.free(self.layers);
}

/// The topmost cloud space Z any of this type's layers can reach.
pub fn maxHeight(self: CloudType) f32 {
	var result: f32 = 0;
	for (self.layers) |layer| result = @max(result, layer.heightOffset + layer.height);
	return result;
}

/// The lowest cloud space Z any of this type's layers can reach.
pub fn minHeight(self: CloudType) f32 {
	if (self.layers.len == 0) return 0;
	var result: f32 = std.math.floatMax(f32);
	for (self.layers) |layer| result = @min(result, layer.heightOffset);
	return result;
}

// MARK: registry

/// Index 0 is always the empty type, so that a region texture cleared to zero
/// produces no clouds at all.
pub const emptyIndex: u32 = 0;

var arena: main.heap.NeverFailingArenaAllocator = undefined;
var types: main.ListManaged(CloudType) = undefined;
var indexById: std.StringHashMapUnmanaged(u32) = .{};

pub fn initRegistry() void {
	arena = .init(main.globalAllocator);
	types = .init(arena.allocator());
	indexById = .{};

	types.append(.{
		.id = "cubyz:empty",
		.layers = &.{},
		.weather = .none,
		.storminess = 0,
		.stormStart = 0,
		.stormFadeDistance = 1,
		.transparencyFade = 0,
		.spawning = .{.weight = 0},
	});

	loadFrom("assets/cubyz/cloud_types");

	if (types.items.len == 1) {
		std.log.err("No cloud types were loaded, clouds will not be rendered.", .{});
	}
	std.log.info("Loaded {} cloud types.", .{types.items.len - 1});
}

fn loadFrom(path: []const u8) void {
	var dir = main.files.cwd().openIterableDir(path) catch |err| {
		std.log.err("Could not open cloud type directory {s}: {s}", .{path, @errorName(err)});
		return;
	};
	defer dir.close();

	var iterator = dir.iterate();
	while (iterator.next(main.io) catch |err| {
		std.log.err("Could not iterate cloud type directory {s}: {s}", .{path, @errorName(err)});
		return;
	}) |entry| {
		if (entry.kind != .file) continue;
		if (!std.ascii.endsWithIgnoreCase(entry.name, ".zon")) continue;
		if (types.items.len >= maxCloudTypes) {
			std.log.err("Too many cloud types, at most {} are supported.", .{maxCloudTypes});
			return;
		}

		const zon = dir.readToZon(main.stackAllocator, entry.name) catch |err| {
			std.log.err("Could not read cloud type {s}: {s}", .{entry.name, @errorName(err)});
			continue;
		};
		defer zon.deinit(main.stackAllocator);

		const name = entry.name[0..std.mem.indexOfScalar(u8, entry.name, '.').?];
		const id = main.stackAllocator.print("cubyz:{s}", .{name});
		defer main.stackAllocator.free(id);

		const cloudType = fromZon(arena.allocator(), id, zon);
		indexById.put(arena.allocator().allocator, cloudType.id, @intCast(types.items.len)) catch unreachable;
		types.append(cloudType);
	}
}

pub fn deinitRegistry() void {
	indexById = .{};
	arena.deinit();
}

pub fn all() []const CloudType {
	return types.items;
}

pub fn get(index: u32) *const CloudType {
	if (index >= types.items.len) return &types.items[emptyIndex];
	return &types.items[index];
}

pub fn indexOf(id: []const u8) ?u32 {
	if (indexById.get(id)) |index| return index;
	if (std.mem.indexOfScalar(u8, id, ':') != null) return null;
	var buf: [128]u8 = undefined;
	const prefixed = std.fmt.bufPrint(&buf, "cubyz:{s}", .{id}) catch return null;
	return indexById.get(prefixed);
}

/// Flattens every type into the two buffers the compute shader expects.
pub fn packForGpu(allocator: main.heap.NeverFailingAllocator, outLayers: *[]GpuNoiseLayer, outGroups: *[]GpuLayerGroup) void {
	var totalLayers: usize = 0;
	for (types.items) |cloudType| totalLayers += cloudType.layers.len;

	// The shader indexes these unconditionally, so never hand it an empty buffer.
	const layers = allocator.alloc(GpuNoiseLayer, @max(totalLayers, 1));
	const groups = allocator.alloc(GpuLayerGroup, types.items.len);

	var cursor: usize = 0;
	for (types.items, groups) |cloudType, *group| {
		group.* = .{
			.startIndex = @intCast(cursor),
			.endIndex = @intCast(cursor + cloudType.layers.len),
			.storminess = cloudType.storminess,
			.stormStart = cloudType.stormStart,
			.stormFadeDistance = cloudType.stormFadeDistance,
			.transparencyFade = cloudType.transparencyFade,
		};
		for (cloudType.layers) |layer| {
			layers[cursor] = .{
				.height = layer.height,
				.valueOffset = layer.valueOffset,
				.scaleX = layer.scaleX,
				.scaleY = layer.scaleY,
				.scaleZ = layer.scaleZ,
				.fadeDistance = layer.fadeDistance,
				.heightOffset = layer.heightOffset,
				.valueScale = layer.valueScale,
			};
			cursor += 1;
		}
	}
	if (totalLayers == 0) layers[0] = std.mem.zeroes(GpuNoiseLayer);

	outLayers.* = layers;
	outGroups.* = groups;
}

/// Vertical bounds in cloud space that cover every loaded type, used to size the
/// compute dispatch when the exact type at a position is not known yet.
pub fn globalHeightBounds() struct { min: f32, max: f32 } {
	var min: f32 = 0;
	var max: f32 = 0;
	for (types.items) |cloudType| {
		if (cloudType.layers.len == 0) continue;
		min = @min(min, cloudType.minHeight());
		max = @max(max, cloudType.maxHeight());
	}
	max = @min(max, @as(f32, main.weather.verticalChunkSpan*main.weather.chunkSize));
	return .{.min = min, .max = max};
}
