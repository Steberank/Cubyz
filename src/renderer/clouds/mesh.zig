//! Cloud mesh generation.
//!
//! The visible cloud area is covered by concentric square rings of chunks, each
//! split into 32-voxel-tall slabs. A cumulonimbus is eight slabs high; treating
//! the whole column as one mesh overflows the per-chunk face budget and the
//! dropped faces flicker because GPU atomics pick a different subset each time.
//!
//! The innermost rings use one voxel per cloud space unit; every outer ring
//! doubles the voxel size, so the vertex count stays roughly constant as the
//! area grows.
//!
//! Generation is spread over several frames: when the queue runs dry, the whole
//! ring layout is frustum culled and re-enqueued, and a fixed slice of the queue
//! is dispatched each frame. Each chunk owns a fixed section of one shared
//! buffer, so all the host has to read back is one counter per chunk.

const std = @import("std");

const main = @import("main");
const graphics = main.graphics;
const settings = main.settings;
const vec = main.vec;
const Vec2d = vec.Vec2d;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;

const c = @import("c");

const clouds = @import("../clouds.zig");
const CloudType = main.weather.CloudType;
const regions = @import("regions.zig");

pub const LevelOfDetail = struct {
	/// How many cloud space units one voxel spans in this ring.
	chunkScale: u31,
	/// How many rings of chunks this level contributes.
	spread: u31,
};

/// Width of the innermost, full detail area in chunks.
fn primaryChunkSpanFor(quality: settings.CloudQuality) u31 {
	return switch (quality) {
		.low, .medium => 4,
		.high => 8,
	};
}

/// Coarser rings around the full detail area, from the inside out.
fn lodsFor(quality: settings.CloudQuality) []const LevelOfDetail {
	return switch (quality) {
		.low => &.{.{.chunkScale = 2, .spread = 1}, .{.chunkScale = 4, .spread = 3}, .{.chunkScale = 8, .spread = 3}},
		.medium => &.{.{.chunkScale = 2, .spread = 3}, .{.chunkScale = 4, .spread = 4}, .{.chunkScale = 8, .spread = 2}},
		.high => &.{.{.chunkScale = 2, .spread = 4}, .{.chunkScale = 4, .spread = 3}, .{.chunkScale = 8, .spread = 2}},
	};
}

/// A chunk of the ring layout, in chunk grid coordinates at its own LOD scale.
const PreparedChunk = struct {
	lodLevel: u31,
	lodScale: u31,
	x: i32,
	y: i32,
	/// Vertical slab index. Each slab is `chunkSize` voxels tall, so a full
	/// cumulonimbus is `verticalChunkSpan` slabs at LOD 0.
	z: i32,
	/// Face index whose occlusion test is skipped, or -1. The innermost ring of
	/// each LOD borders a finer ring whose voxels the coarse density field does
	/// not see, so that border would otherwise be left open.
	noOcclusionSide: i32,
};

/// Everything about a chunk's mesh that has to change at the same instant as the
/// mesh data itself. Generating a chunk takes several frames, during which the
/// old mesh keeps being drawn, so the new values are staged here and only
/// published once the whole batch has landed.
const Generation = struct {
	/// Cloud space grid origin the positions in the buffer are relative to.
	origin: Vec2d = .{0, 0},
	/// Vertical cloud space extent of the mesh, for frustum culling.
	minZ: f32 = 0,
	maxZ: f32 = 0,
	opaqueCount: u32 = 0,
	transparentCount: u32 = 0,
};

const MeshChunk = struct {
	info: PreparedChunk,
	/// Which of the chunk's two buffer sections rendering reads. The compute
	/// shader always writes into the other one, so a half finished mesh is never
	/// visible.
	front: u1 = 0,
	current: Generation = .{},
	staged: Generation = .{},
	alpha: f32 = 0,
	secondsEmpty: f32 = 0,

	fn publishStaged(self: *MeshChunk) void {
		self.front ^= 1;
		self.current = self.staged;
	}

	/// Horizontal cloud space bounds relative to the player, which is the frame
	/// of reference `Frustum` works in.
	fn horizontalBounds(self: MeshChunk, playerCloudPos: Vec2d) struct { min: Vec2d, max: Vec2d } {
		const size: f64 = @floatFromInt(clouds.chunkSize*self.info.lodScale);
		const gridPos = Vec2d{@as(f64, @floatFromInt(self.info.x))*size, @as(f64, @floatFromInt(self.info.y))*size};
		const min = gridPos + self.current.origin - playerCloudPos;
		return .{.min = min, .max = min + Vec2d{size, size}};
	}
};

/// Start of one of a chunk's two sections of a shared mesh buffer, in elements.
fn sectionOffset(chunkIndex: usize, slot: u1, maxElements: u32) u32 {
	return @intCast((chunkIndex*2 + slot)*maxElements);
}

const GenTask = struct {
	chunkIndex: u32,
	startZ: f32,
	endZ: f32,
};

/// The opaque cloud surface, and the soft translucent shell around it.
pub const MeshKind = enum { solid, shell };

/// Faces and cubes a single 32³ slab may contribute. A filled cube's hull is
/// 6144 faces; the extra room is for noise cavities. Overflow only costs detail
/// in that one slab. Every slab gets two sections of this size.
const maxOpaqueElementsPerChunk: u32 = 8192;
const maxTransparentElementsPerChunk: u32 = 6144;

const bytesPerSideInfo = 24;
const bytesPerCubeInfo = 24;

/// A chunk has to stay empty for this long before its fade in restarts. Without
/// it, chunks that briefly leave the view would fade in again every time they
/// come back.
const emptyBeforeFadeReset = 2.0;

var lods: []const LevelOfDetail = &.{};
var primaryChunkSpan: u31 = 0;
var effectiveChunkSpan: u31 = 0;
var useTransparency = false;

var arena: main.heap.NeverFailingArenaAllocator = undefined;
var chunks: []MeshChunk = &.{};

var meshPipeline: graphics.ComputePipeline = undefined;
var meshUniforms: struct {
	regionsTexSize: c_int,
	regionSampleOffset: c_int,
	lodLevel: c_int,
	renderOffset: c_int,
	noiseOrigin: c_int,
	scale: c_int,
	scroll: c_int,
	wiggle: c_int,
	origin: c_int,
	generateHiddenFaces: c_int,
	doNotOccludeSide: c_int,
	chunkIndex: c_int,
	fadeStart: c_int,
	fadeEnd: c_int,
	transparencyDistance: c_int,
	opaqueMeshOffset: c_int,
	maxOpaqueElements: c_int,
	transparentMeshOffset: c_int,
	maxTransparentElements: c_int,
} = undefined;

var sidePool: graphics.SSBO = undefined;
var sidesPerChunk: graphics.SSBO = undefined;
var cubePool: graphics.SSBO = undefined;
var cubesPerChunk: graphics.SSBO = undefined;

var taskQueue: main.ListManaged(GenTask) = undefined;
var taskCursor: usize = 0;
var pendingChunks: main.ListManaged(u32) = undefined;
var tasksPerFrame: usize = 1;
var batchOrigin: Vec2d = .{0, 0};
var regionTextureSize: u31 = 0;
var reportedOverflow = false;

// MARK: init

pub fn init(quality: settings.CloudQuality, transparency: bool) void {
	useTransparency = transparency;
	lods = lodsFor(quality);
	primaryChunkSpan = primaryChunkSpanFor(quality);

	arena = .init(main.globalAllocator);
	taskQueue = .init(main.globalAllocator);
	pendingChunks = .init(main.globalAllocator);
	taskCursor = 0;
	reportedOverflow = false;

	buildChunkLayout();

	var defines: main.List(u8) = .empty;
	defer defines.deinit(main.stackAllocator);
	if (useTransparency) defines.appendSlice(main.stackAllocator, "#define TRANSPARENCY\n");
	if (settings.cloudShading) defines.appendSlice(main.stackAllocator, "#define SHADED\n");
	defines.append(main.stackAllocator, 0);
	meshPipeline = .init("assets/cubyz/shaders/clouds/cube_mesh.comp", defines.items[0 .. defines.items.len - 1], &meshUniforms);

	// Two sections per chunk, so that generating into one never disturbs the one
	// being drawn.
	sidePool = .initDynamicSize([bytesPerSideInfo]u8, chunks.len*2*maxOpaqueElementsPerChunk);
	sidesPerChunk = .initDynamicSize(u32, chunks.len);
	zeroCounters(sidesPerChunk, chunks.len);
	if (useTransparency) {
		cubePool = .initDynamicSize([bytesPerCubeInfo]u8, chunks.len*2*maxTransparentElementsPerChunk);
		cubesPerChunk = .initDynamicSize(u32, chunks.len);
		zeroCounters(cubesPerChunk, chunks.len);
	}

	regionTextureSize = computeRegionTextureSize();
	const lodScales = main.stackAllocator.alloc(f32, lods.len + 1);
	defer main.stackAllocator.free(lodScales);
	lodScales[0] = 1;
	for (lods, lodScales[1..]) |lod, *scale| scale.* = @floatFromInt(lod.chunkScale);
	regions.init(regionTextureSize, lodScales);

	std.log.info("Cloud mesh: {} chunks, radius {d:.0} blocks, region texture {}", .{
		chunks.len,
		maxRadius()*clouds.cloudScale,
		regionTextureSize,
	});
}

pub fn deinit() void {
	regions.deinit();
	if (useTransparency) {
		cubesPerChunk.deinit();
		cubePool.deinit();
	}
	sidesPerChunk.deinit();
	sidePool.deinit();
	meshPipeline.deinit();
	pendingChunks.deinit();
	taskQueue.deinit();
	arena.deinit();
	chunks = &.{};
}

fn zeroCounters(ssbo: graphics.SSBO, count: usize) void {
	const zeros = main.stackAllocator.alloc(u32, count);
	defer main.stackAllocator.free(zeros);
	@memset(zeros, 0);
	ssbo.bufferSubData(u32, zeros, count);
}

/// Builds the concentric ring layout, innermost ring first, so that the chunks
/// closest to the player are also generated first.
fn buildChunkLayout() void {
	var list: main.ListManaged(MeshChunk) = .init(arena.allocator());

	var currentRadius: i32 = primaryChunkSpan/2;
	{
		var r: i32 = 0;
		while (r <= currentRadius) : (r += 1) {
			var x: i32 = -r;
			while (x < r) : (x += 1) {
				appendColumn(&list, .{.lodLevel = 0, .lodScale = 1, .x = x, .y = -r, .z = 0, .noOcclusionSide = -1});
				appendColumn(&list, .{.lodLevel = 0, .lodScale = 1, .x = x, .y = r - 1, .z = 0, .noOcclusionSide = -1});
			}
			var y: i32 = -r + 1;
			while (y < r - 1) : (y += 1) {
				appendColumn(&list, .{.lodLevel = 0, .lodScale = 1, .x = -r, .y = y, .z = 0, .noOcclusionSide = -1});
				appendColumn(&list, .{.lodLevel = 0, .lodScale = 1, .x = r - 1, .y = y, .z = 0, .noOcclusionSide = -1});
			}
		}
	}

	for (lods, 0..) |lod, i| {
		const lodLevel: u31 = @intCast(i + 1);
		const scale: i32 = lod.chunkScale;
		var deltaR: i32 = 1;
		while (deltaR <= lod.spread) : (deltaR += 1) {
			// Only the ring facing the finer detail area needs its border kept.
			const bordersFinerRing = deltaR == 1;
			const r = @divTrunc(currentRadius, scale) + deltaR;
			var x: i32 = -r;
			while (x < r) : (x += 1) {
				appendColumn(&list, .{.lodLevel = lodLevel, .lodScale = lod.chunkScale, .x = x, .y = -r, .z = 0, .noOcclusionSide = if (bordersFinerRing) 3 else -1});
				appendColumn(&list, .{.lodLevel = lodLevel, .lodScale = lod.chunkScale, .x = x, .y = r - 1, .z = 0, .noOcclusionSide = if (bordersFinerRing) 2 else -1});
			}
			var y: i32 = -r + 1;
			while (y < r - 1) : (y += 1) {
				appendColumn(&list, .{.lodLevel = lodLevel, .lodScale = lod.chunkScale, .x = -r, .y = y, .z = 0, .noOcclusionSide = if (bordersFinerRing) 1 else -1});
				appendColumn(&list, .{.lodLevel = lodLevel, .lodScale = lod.chunkScale, .x = r - 1, .y = y, .z = 0, .noOcclusionSide = if (bordersFinerRing) 0 else -1});
			}
		}
		currentRadius += lod.spread*scale;
	}

	effectiveChunkSpan = @intCast(currentRadius*2);
	chunks = list.items;
}

/// How many 32-voxel-tall slabs stack to the top of the cloud volume at this LOD.
fn verticalSlices(lodScale: u31) i32 {
	return @intCast(@divExact(clouds.verticalChunkSpan, lodScale));
}

fn sliceHeight(lodScale: u31) f32 {
	return @floatFromInt(clouds.chunkSize*lodScale);
}

/// One horizontal column becomes several stacked slabs, each with its own face
/// budget, so a 256-tall storm does not have to share 8192 faces across its
/// whole height.
fn appendColumn(list: *main.ListManaged(MeshChunk), info: PreparedChunk) void {
	const slices = verticalSlices(info.lodScale);
	var z: i32 = 0;
	while (z < slices) : (z += 1) {
		var slice = info;
		slice.z = z;
		list.append(.{.info = slice});
	}
}

/// The region texture has to cover the widest ring at every LOD, expressed in
/// that LOD's own voxels.
fn computeRegionTextureSize() u31 {
	var previousSpan: u31 = primaryChunkSpan;
	var previousScale: u31 = 1;
	var largestSpan: u31 = previousSpan;
	for (lods) |lod| {
		previousSpan = previousSpan/(lod.chunkScale/previousScale) + lod.spread*2;
		previousScale = lod.chunkScale;
		largestSpan = @max(largestSpan, previousSpan);
	}
	// The region compute shader uses 8x8 work groups.
	return std.mem.alignForward(u31, largestSpan*clouds.chunkSize, 8);
}

/// Radius of the covered area, in cloud space units.
pub fn maxRadius() f32 {
	return @floatFromInt(effectiveChunkSpan*clouds.chunkSize/2);
}

pub fn chunkCount() usize {
	return chunks.len;
}

// MARK: generation

/// Runs one frame's worth of mesh generation. `playerPos` is in blocks.
pub fn generate(frustum: *const main.renderer.Frustum, playerPos: Vec3d, scroll: Vec3f) void {
	const cloudOrigin = clouds.toCloudSpace(playerPos);

	if (taskCursor >= taskQueue.items.len) {
		finishBatch();
		startBatch(frustum, cloudOrigin, scroll);
	}

	dispatchTasks();
}

/// Reads back the per chunk counters produced by the batch that just finished,
/// resets them, and publishes the freshly generated meshes all at once. Doing
/// the swap in one go is what keeps a chunk from ever being drawn with the
/// element count of one batch and the contents of another.
fn finishBatch() void {
	if (pendingChunks.items.len == 0) return;

	c.glMemoryBarrier(c.GL_SHADER_STORAGE_BARRIER_BIT);

	readCounters(sidesPerChunk, maxOpaqueElementsPerChunk, .solid);
	if (useTransparency) readCounters(cubesPerChunk, maxTransparentElementsPerChunk, .shell);

	for (pendingChunks.items) |chunkIndex| chunks[chunkIndex].publishStaged();

	pendingChunks.clearRetainingCapacity();
}

fn readCounters(ssbo: graphics.SSBO, maxElements: u32, kind: MeshKind) void {
	c.glBindBuffer(c.GL_SHADER_STORAGE_BUFFER, ssbo.bufferID);
	const mapped = c.glMapBufferRange(
		c.GL_SHADER_STORAGE_BUFFER,
		0,
		@intCast(chunks.len*@sizeOf(u32)),
		c.GL_MAP_READ_BIT | c.GL_MAP_WRITE_BIT,
	) orelse {
		std.log.err("Could not map the cloud mesh counters.", .{});
		c.glBindBuffer(c.GL_SHADER_STORAGE_BUFFER, 0);
		return;
	};
	const counters: [*]u32 = @ptrCast(@alignCast(mapped));

	for (pendingChunks.items) |chunkIndex| {
		const chunk = &chunks[chunkIndex];
		const produced = counters[chunkIndex];
		// Clamping away a handful of elements is invisible, so only complain
		// when a chunk overflows by enough to leave real holes.
		if (produced > maxElements + maxElements/20 and !reportedOverflow) {
			reportedOverflow = true;
			std.log.warn("A cloud chunk needed {} {s} elements but only {} fit. Some clouds will have holes.", .{produced, @tagName(kind), maxElements});
		}
		const count = @min(produced, maxElements);
		switch (kind) {
			.solid => chunk.staged.opaqueCount = count,
			.shell => chunk.staged.transparentCount = count,
		}
		counters[chunkIndex] = 0;
	}

	std.debug.assert(c.glUnmapBuffer(c.GL_SHADER_STORAGE_BUFFER) == c.GL_TRUE);
	c.glBindBuffer(c.GL_SHADER_STORAGE_BUFFER, 0);
}

/// Culls the ring layout and queues the chunks that are worth generating.
fn startBatch(frustum: *const main.renderer.Frustum, cloudOrigin: Vec3d, scroll: Vec3f) void {
	taskQueue.clearRetainingCapacity();
	taskCursor = 0;

	const gridSize: f64 = clouds.chunkSize;
	batchOrigin = .{@floor(cloudOrigin[0]/gridSize)*gridSize, @floor(cloudOrigin[1]/gridSize)*gridSize};

	regions.upload(batchOrigin);

	const radius = maxRadius();
	const fadeStart = 0.9*radius;
	const cullDistance = clouds.fogEnd()/clouds.cloudScale;

	meshPipeline.bind();
	c.glUniform1i(meshUniforms.regionsTexSize, regionTextureSize);
	c.glUniform3f(meshUniforms.scroll, scroll[0], scroll[1], scroll[2]);
	c.glUniform1f(meshUniforms.wiggle, (scroll[0] + scroll[1] + scroll[2])/5);
	c.glUniform1i(meshUniforms.generateHiddenFaces, if (settings.cloudHiddenFaces) 1 else 0);
	c.glUniform1f(meshUniforms.fadeStart, fadeStart);
	c.glUniform1f(meshUniforms.fadeEnd, radius);
	c.glUniform1f(meshUniforms.transparencyDistance, radius*settings.cloudTransparencyDistance);
	c.glUniform1i(meshUniforms.maxOpaqueElements, @intCast(maxOpaqueElementsPerChunk));
	if (useTransparency) c.glUniform1i(meshUniforms.maxTransparentElements, @intCast(maxTransparentElementsPerChunk));

	const relativeOrigin: Vec3f = @floatCast(cloudOrigin - Vec3d{batchOrigin[0], batchOrigin[1], 0});
	c.glUniform3f(meshUniforms.origin, relativeOrigin[0], relativeOrigin[1], relativeOrigin[2]);

	const noiseOrigin = clouds.wrapNoiseOrigin(batchOrigin);
	c.glUniform3f(meshUniforms.noiseOrigin, noiseOrigin[0], noiseOrigin[1], 0);

	// Offset from the chunk grid to the player, since the frustum works in
	// player relative coordinates.
	const playerOffset = Vec2d{batchOrigin[0] - cloudOrigin[0], batchOrigin[1] - cloudOrigin[1]};

	for (chunks, 0..) |*chunk, index| {
		// The bounds a chunk is about to be generated at, not the ones it
		// currently holds.
		const size: f64 = @floatFromInt(clouds.chunkSize*chunk.info.lodScale);
		const min = Vec2d{@as(f64, @floatFromInt(chunk.info.x))*size, @as(f64, @floatFromInt(chunk.info.y))*size};
		const max = min + Vec2d{size, size};
		const slabHeight = sliceHeight(chunk.info.lodScale);
		const slabMinZ = @as(f32, @floatFromInt(chunk.info.z))*slabHeight;
		const slabMaxZ = slabMinZ + slabHeight;

		const heights = if (isChunkVisible(frustum, min + playerOffset, max + playerOffset, slabMinZ, slabMaxZ, cloudOrigin[2], cullDistance))
			determineHeights(min + batchOrigin, max + batchOrigin)
		else
			ChunkHeights{.min = 0, .max = 0, .empty = true};

		const genMin = @max(heights.min, slabMinZ);
		const genMax = @min(heights.max, slabMaxZ);
		if (heights.empty or genMin >= genMax) {
			// Staged rather than cleared right away: the chunk keeps drawing its
			// old mesh until the rest of the batch catches up, otherwise clouds
			// would blink out for the few frames a batch takes.
			chunk.staged.opaqueCount = 0;
			chunk.staged.transparentCount = 0;
			pendingChunks.append(@intCast(index));
			continue;
		}

		taskQueue.append(.{.chunkIndex = @intCast(index), .startZ = genMin, .endZ = genMax});
	}

	const interval = generationInterval();
	tasksPerFrame = @max((taskQueue.items.len + interval - 1)/interval, 1);
}

/// How far outside the frustum chunks are still generated. Entering the view
/// costs a whole batch plus a fade in, so keeping a ring of ready chunks around
/// the edges stops clouds from arriving late when the camera turns.
const generationMargin = clouds.chunkSize;

/// Rejects chunks outside the fog distance or the view frustum. `min` and `max`
/// are horizontal cloud space bounds relative to the player. `minZ`/`maxZ` are
/// the slab's vertical range in cloud space. Distances are measured to the
/// nearest corner so the chunk the player stands in is never culled.
fn isChunkVisible(frustum: *const main.renderer.Frustum, min: Vec2d, max: Vec2d, minZ: f32, maxZ: f32, playerCloudZ: f64, cullDistance: f32) bool {
	const nearestX = @max(@max(min[0], -max[0]), 0);
	const nearestY = @max(@max(min[1], -max[1]), 0);
	if (cullDistance > 0 and @sqrt(nearestX*nearestX + nearestY*nearestY) > cullDistance) return false;

	// The frustum works in blocks relative to the player. Cloud space Z is
	// measured from the cloud layer, whose height above the player is
	// `-playerCloudZ * cloudScale`.
	const base: f32 = @floatCast(-playerCloudZ*clouds.cloudScale);
	const margin = generationMargin*clouds.cloudScale;
	const worldMin = Vec3f{
		@floatCast(min[0]*clouds.cloudScale - margin),
		@floatCast(min[1]*clouds.cloudScale - margin),
		base + minZ*clouds.cloudScale,
	};
	const worldSize = Vec3f{
		@floatCast((max[0] - min[0])*clouds.cloudScale + 2*margin),
		@floatCast((max[1] - min[1])*clouds.cloudScale + 2*margin),
		(maxZ - minZ)*clouds.cloudScale,
	};
	return frustum.testAAB(worldMin, worldSize);
}

const ChunkHeights = struct { min: f32, max: f32, empty: bool };

/// Samples the four corners of a chunk to find the vertical range that actually
/// needs generating, and whether there is any cloud there at all.
fn determineHeights(min: Vec2d, max: Vec2d) ChunkHeights {
	const corners = [4]Vec2d{min, .{min[0], max[1]}, .{max[0], min[1]}, max};

	var lowest: f32 = std.math.floatMax(f32);
	var highest: f32 = -std.math.floatMax(f32);
	var empty = true;

	for (corners) |corner| {
		const sample = regions.sampleAt(corner);
		if (sample.presence > 0) empty = false;
		const cloudType = CloudType.get(sample.typeIndex);
		if (cloudType.layers.len == 0) continue;
		lowest = @min(lowest, cloudType.minHeight());
		highest = @max(highest, cloudType.maxHeight());
	}

	if (empty or highest <= lowest) return .{.min = 0, .max = 0, .empty = true};
	return .{.min = @floor(lowest), .max = @ceil(@min(highest, @as(f32, clouds.verticalChunkSpan*clouds.chunkSize))), .empty = false};
}

/// How many frames a full regeneration of the cloud mesh may take. Spreading the
/// work out keeps the compute dispatches from causing frame spikes.
fn generationInterval() usize {
	const deltaTime = main.lastDeltaTime.load(.monotonic);
	const fps: f64 = if (deltaTime > 0) 1/deltaTime else 60;
	return switch (settings.cloudGenerationInterval) {
		.static => @max(settings.cloudGenerationFrames, 1),
		.dynamic => @max(@as(usize, @intFromFloat(@max(@ceil((130 - fps)/30), 0))) + 5, 1),
		.targetFps => @max(@as(usize, @intFromFloat(@ceil(fps/@as(f64, @floatFromInt(@max(settings.cloudTargetGenerationFps, 1)))))), 1),
	};
}

fn dispatchTasks() void {
	if (taskCursor >= taskQueue.items.len) return;

	meshPipeline.bind();
	regions.bindTexture();
	sidePool.bind(clouds.bindings.sideInfo);
	sidesPerChunk.bind(clouds.bindings.sidesPerChunk);
	if (useTransparency) {
		cubePool.bind(clouds.bindings.transparentCubeInfo);
		cubesPerChunk.bind(clouds.bindings.transparentCubesPerChunk);
	}
	clouds.bindCloudTypeBuffers();

	const end = @min(taskCursor + tasksPerFrame, taskQueue.items.len);
	for (taskQueue.items[taskCursor..end]) |task| {
		dispatchChunk(task);
		pendingChunks.append(task.chunkIndex);
	}
	taskCursor = end;
}

fn dispatchChunk(task: GenTask) void {
	const chunk = &chunks[task.chunkIndex];
	const info = chunk.info;

	const scale: f32 = @floatFromInt(info.lodScale);
	const voxelsHigh = @ceil((task.endZ - task.startZ)/scale);
	const workGroupsZ: u32 = @intFromFloat(@ceil(voxelsHigh/clouds.localSize));
	if (workGroupsZ == 0) {
		chunk.staged.opaqueCount = 0;
		chunk.staged.transparentCount = 0;
		return;
	}

	const chunkExtent: f32 = @floatFromInt(clouds.chunkSize*info.lodScale);
	const renderOffset = Vec3f{
		@as(f32, @floatFromInt(info.x))*chunkExtent,
		@as(f32, @floatFromInt(info.y))*chunkExtent,
		task.startZ,
	};

	// The region texture is indexed in each LOD's own voxels, centred on the grid.
	const halfTexture: f32 = @as(f32, @floatFromInt(regionTextureSize))/2;
	c.glUniform2f(
		meshUniforms.regionSampleOffset,
		@as(f32, @floatFromInt(info.x*clouds.chunkSize)) + halfTexture,
		@as(f32, @floatFromInt(info.y*clouds.chunkSize)) + halfTexture,
	);
	c.glUniform1i(meshUniforms.lodLevel, info.lodLevel);
	c.glUniform3f(meshUniforms.renderOffset, renderOffset[0], renderOffset[1], renderOffset[2]);
	c.glUniform1f(meshUniforms.scale, scale);
	c.glUniform1i(meshUniforms.doNotOccludeSide, info.noOcclusionSide);
	c.glUniform1i(meshUniforms.chunkIndex, @intCast(task.chunkIndex));

	// Generate into the section that is not being drawn.
	const back = chunk.front ^ 1;
	c.glUniform1i(meshUniforms.opaqueMeshOffset, @intCast(sectionOffset(task.chunkIndex, back, maxOpaqueElementsPerChunk)));
	if (useTransparency) c.glUniform1i(meshUniforms.transparentMeshOffset, @intCast(sectionOffset(task.chunkIndex, back, maxTransparentElementsPerChunk)));

	c.glDispatchCompute(clouds.workSize, clouds.workSize, workGroupsZ);

	// Only takes effect once the whole batch is published.
	chunk.staged.origin = batchOrigin;
	chunk.staged.minZ = task.startZ;
	chunk.staged.maxZ = task.endZ;
}

// MARK: rendering

pub const RenderableChunk = struct {
	/// Offset from the player to this chunk's cloud space origin, in blocks.
	cloudOffset: Vec3f,
	firstElement: u32,
	elementCount: u32,
	alpha: f32,
};

/// Advances the fade in of freshly generated chunks.
pub fn advanceFade(deltaTime: f64) void {
	const step: f32 = @floatCast(deltaTime*clouds.chunkFadeInPerSecond);
	for (chunks) |*chunk| {
		if (chunk.current.opaqueCount == 0 and chunk.current.transparentCount == 0) {
			chunk.secondsEmpty += @floatCast(deltaTime);
			if (chunk.secondsEmpty > emptyBeforeFadeReset) chunk.alpha = 0;
			continue;
		}
		chunk.secondsEmpty = 0;
		chunk.alpha = @min(chunk.alpha + step, 1);
	}
}

/// Collects the chunks that have geometry and survive frustum culling. The
/// caller owns the returned slice.
pub fn collectRenderable(
	allocator: main.heap.NeverFailingAllocator,
	frustum: *const main.renderer.Frustum,
	playerPos: Vec3d,
	kind: MeshKind,
) []RenderableChunk {
	var result: main.ListManaged(RenderableChunk) = .initCapacity(allocator, chunks.len);

	const cloudOrigin = clouds.toCloudSpace(playerPos);
	const playerCloudPos = Vec2d{cloudOrigin[0], cloudOrigin[1]};

	for (chunks, 0..) |chunk, index| {
		const elementCount = switch (kind) {
			.solid => chunk.current.opaqueCount,
			.shell => chunk.current.transparentCount,
		};
		if (elementCount == 0) continue;

		const bounds = chunk.horizontalBounds(playerCloudPos);
		// The compute shader rounds the vertical range up to whole work groups,
		// so the geometry can reach a little above `maxZ`.
		const verticalPadding = clouds.localSize*@as(f32, @floatFromInt(chunk.info.lodScale));
		const worldMin = Vec3f{
			@floatCast(bounds.min[0]*clouds.cloudScale),
			@floatCast(bounds.min[1]*clouds.cloudScale),
			chunk.current.minZ*clouds.cloudScale + clouds.heightAbovePlayer(playerPos),
		};
		const worldSize = Vec3f{
			@floatCast((bounds.max[0] - bounds.min[0])*clouds.cloudScale),
			@floatCast((bounds.max[1] - bounds.min[1])*clouds.cloudScale),
			(chunk.current.maxZ - chunk.current.minZ + verticalPadding)*clouds.cloudScale,
		};
		if (!frustum.testAAB(worldMin, worldSize)) continue;

		const maxElements = switch (kind) {
			.solid => maxOpaqueElementsPerChunk,
			.shell => maxTransparentElementsPerChunk,
		};
		result.append(.{
			.cloudOffset = .{
				@floatCast(chunk.current.origin[0]*clouds.cloudScale - playerPos[0]),
				@floatCast(chunk.current.origin[1]*clouds.cloudScale - playerPos[1]),
				clouds.heightAbovePlayer(playerPos),
			},
			.firstElement = sectionOffset(index, chunk.front, maxElements),
			.elementCount = elementCount,
			.alpha = chunk.alpha,
		});
	}

	return result.toOwnedSlice();
}

pub fn bindOpaquePool() void {
	sidePool.bind(clouds.bindings.sideInfo);
}

pub fn bindTransparentPool() void {
	if (useTransparency) cubePool.bind(clouds.bindings.transparentCubeInfo);
}

pub fn transparencyEnabled() bool {
	return useTransparency;
}
