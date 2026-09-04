//! Cloud regions: the elliptical formations that decide which cloud type covers
//! which part of the world, and therefore also where it rains.
//!
//! Regions are rasterized on the GPU into a small `RG32F` array texture (one
//! slice per LOD level) holding the cloud type index and an edge fade factor.
//! The mesh generator samples that texture per voxel; the CPU keeps the same
//! data around so it can answer weather queries and skip empty chunks.
//!
//! The formations themselves belong to the server. This module only holds the
//! most recent snapshot it sent and advances it locally between snapshots, so
//! that the clouds keep drifting smoothly instead of stepping every time one
//! arrives.

const std = @import("std");

const main = @import("main");
const graphics = main.graphics;
const vec = main.vec;
const Vec2d = vec.Vec2d;
const Vec2f = vec.Vec2f;
const Region = main.weather.Region;

const c = @import("c");

const clouds = @import("../clouds.zig");

/// Layout of `CloudRegion` in `cloud_regions.comp`. 32 bytes, matching the
/// std430 layout of four floats followed by a `mat2`.
const GpuRegion = extern struct {
	posX: f32,
	posY: f32,
	index: f32,
	radius: f32,
	transform: [4]f32,
};

comptime {
	std.debug.assert(@sizeOf(GpuRegion) == 32);
}

/// The formations the renderer draws. Only touched on the render thread.
pub var active: main.ListManaged(Region) = undefined;

/// The last snapshot the server sent. Snapshots arrive on the network thread, so
/// it is parked here behind a mutex until the render thread picks it up. It is a
/// fixed array rather than a list so that it has no lifecycle of its own and
/// survives the mesh generator being rebuilt.
var lastSnapshot: [main.weather.maxFormations]Region = undefined;
var lastSnapshotLen: usize = 0;
var snapshotMutex: main.utils.Mutex = .{};
var snapshotIsNew: bool = false;

var regionPipeline: graphics.ComputePipeline = undefined;
var regionUniforms: struct {
	totalCloudRegions: c_int,
} = undefined;
var regionSsbo: graphics.SSBO = undefined;
var lodScaleSsbo: graphics.SSBO = undefined;
var regionTexture: c_uint = undefined;
var textureSize: u31 = 0;
var lodLayers: u31 = 0;

pub fn init(texSize: u31, lodScales: []const f32) void {
	active = .init(main.globalAllocator);
	textureSize = texSize;
	lodLayers = @intCast(lodScales.len);

	regionPipeline = .init("assets/cubyz/shaders/clouds/cloud_regions.comp", "", &regionUniforms);
	regionSsbo = .initDynamicSize(GpuRegion, main.weather.maxFormations);
	lodScaleSsbo = .initStatic(f32, lodScales);

	c.glGenTextures(1, &regionTexture);
	c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, regionTexture);
	c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
	c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
	c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
	c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
	c.glTexImage3D(c.GL_TEXTURE_2D_ARRAY, 0, c.GL_RG32F, textureSize, textureSize, lodLayers, 0, c.GL_RG, c.GL_FLOAT, null);
	c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, 0);
}

pub fn deinit() void {
	c.glDeleteTextures(1, &regionTexture);
	lodScaleSsbo.deinit();
	regionSsbo.deinit();
	regionPipeline.deinit();
	active.deinit();
}

/// Called from the network thread whenever the server sends its weather.
pub fn receiveSnapshot(regions: []const Region) void {
	snapshotMutex.lock();
	defer snapshotMutex.unlock();
	lastSnapshotLen = @min(regions.len, lastSnapshot.len);
	@memcpy(lastSnapshot[0..lastSnapshotLen], regions[0..lastSnapshotLen]);
	snapshotIsNew = true;
}

/// Forgets the server's weather, for when the player leaves the world.
pub fn reset() void {
	snapshotMutex.lock();
	defer snapshotMutex.unlock();
	lastSnapshotLen = 0;
	snapshotIsNew = true;
}

/// Adopts the newest snapshot if one arrived, then advances the formations so
/// their motion stays smooth between the server's updates.
pub fn advance(deltaTime: f32) void {
	{
		snapshotMutex.lock();
		defer snapshotMutex.unlock();
		// Reapplying when the list is empty restores the weather after the mesh
		// generator was rebuilt, without waiting for the next broadcast.
		if (snapshotIsNew or (active.items.len == 0 and lastSnapshotLen != 0)) {
			snapshotIsNew = false;
			active.clearRetainingCapacity();
			active.appendSlice(lastSnapshot[0..lastSnapshotLen]);
		}
	}

	for (active.items) |*region| region.advance(deltaTime);
}

/// The cloud type and weather strength at a horizontal cloud space position.
pub fn sampleAt(pos: Vec2d) main.weather.Sample {
	return main.weather.sampleAt(active.items, pos);
}

pub fn bindTexture() void {
	c.glActiveTexture(c.GL_TEXTURE0 + clouds.regionTextureUnit);
	c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, regionTexture);
}

/// Rasterizes the current region list into the lookup texture.
///
/// Both the texture coordinates and the region positions are expressed relative
/// to `gridOrigin`, the mesh generation grid origin in cloud space. That keeps
/// the f32 the shader works with precise no matter how far the player has
/// travelled, and it matches the frame of reference the mesh generator samples
/// the texture in.
pub fn upload(gridOrigin: Vec2d) void {
	var gpuRegions: [main.weather.maxFormations]GpuRegion = undefined;
	var count: usize = 0;
	for (active.items) |region| {
		if (count >= gpuRegions.len) break;
		if (region.radius <= 0) continue;
		const relative: Vec2f = @floatCast(region.pos - gridOrigin);
		gpuRegions[count] = .{
			.posX = relative[0],
			.posY = relative[1],
			.index = @floatFromInt(region.typeIndex),
			.radius = region.radius,
			.transform = region.transform(),
		};
		count += 1;
	}

	if (count != 0) regionSsbo.bufferSubData(GpuRegion, gpuRegions[0..count], count);

	regionPipeline.bind();
	regionSsbo.bind(clouds.bindings.cloudRegions);
	lodScaleSsbo.bind(clouds.bindings.lodScales);
	c.glBindImageTexture(0, regionTexture, 0, c.GL_TRUE, 0, c.GL_WRITE_ONLY, c.GL_RG32F);
	c.glUniform1i(regionUniforms.totalCloudRegions, @intCast(count));
	c.glDispatchCompute(@divExact(textureSize, 8), @divExact(textureSize, 8), lodLayers);
	c.glMemoryBarrier(c.GL_TEXTURE_FETCH_BARRIER_BIT | c.GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
}

