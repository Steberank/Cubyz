//! GPU driven volumetric cloud rendering.
//!
//! Clouds are a binary occupancy field sampled from a stack of periodic simplex
//! noise layers. A compute shader walks that field per voxel and emits only the
//! cube faces that are exposed; those faces are then drawn as instanced quads.
//! A second, softer shell around the surface is drawn with weighted blended
//! order independent transparency so cloud edges do not look cut out.
//!
//! Everything happens in *cloud space*: one unit is `cloudScale` blocks, Z is up
//! and the origin sits at `settings.cloudHeight`. Positions handed to the GPU are
//! relative to a chunk grid that follows the player, which keeps f32 precise no
//! matter how far the player is from the world origin.
//!
//! The clouds are drawn into the world framebuffer before the transparent
//! terrain pass, so Cubyz' deferred fog and bloom apply to them like they do to
//! any other geometry.

const std = @import("std");

const main = @import("main");
const game = main.game;
const graphics = main.graphics;
const settings = main.settings;
const vec = main.vec;
const Vec2d = vec.Vec2d;
const Vec2f = vec.Vec2f;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;

const c = @import("c");

pub const mesh = @import("clouds/mesh.zig");
pub const regions = @import("clouds/regions.zig");

const weather = main.weather;
pub const CloudType = weather.CloudType;

// MARK: constants

pub const cloudScale = weather.cloudScale;
pub const chunkSize = weather.chunkSize;
pub const verticalChunkSpan = weather.verticalChunkSpan;
/// Compute shader work group size along each axis.
pub const localSize = 8;
pub const workSize = chunkSize/localSize;

/// A chunk fades in over this long once its mesh is ready.
pub const chunkFadeInPerSecond = 4.0;
const ditherScale = 0.05;
const bayerMatrixSize = 16;

/// Noise is sampled in absolute cloud space, which would lose precision far from
/// the world origin, so the sample origin wraps. The wrap is large enough that
/// the resulting seam is over four million blocks out.
const noiseWrap = 1 << 16;

pub const regionTextureUnit = 9;
const bayerTextureUnit = 6;
const accumTextureUnit = 7;
const revealageTextureUnit = 8;

/// Shader storage buffer bindings. Cubyz uses 0 to 16 elsewhere.
pub const bindings = struct {
	pub const noiseLayers = 20;
	pub const layerGroupings = 21;
	pub const sideInfo = 22;
	pub const sidesPerChunk = 23;
	pub const transparentCubeInfo = 25;
	pub const transparentCubesPerChunk = 26;
	pub const cloudRegions = 28;
	pub const lodScales = 29;
};

const diffuseLightPower = 0.4;
const diffuseAmbientLight = 0.9;
/// Faces in shadow are tinted towards this colour rather than simply darkened.
const darknessColorModifier = Vec3f{0, 0, 0.15};

// MARK: state

const CloudVertex = extern struct {
	pos: [3]f32,

	pub const attributeDescriptions: []const c.VkVertexInputAttributeDescription = &.{
		.{
			.location = 0,
			.format = c.VK_FORMAT_R32G32B32_SFLOAT,
			.offset = @offsetOf(@This(), "pos"),
		},
	};
};

var opaquePipeline: graphics.Pipeline = undefined;
var opaqueUniforms: struct {
	cloudOffset: c_int,
	cloudScale: c_int,
	lightPower: c_int,
	ambientLight: c_int,
	darknessColorModifier: c_int,
	useNormals: c_int,
	firstElement: c_int,
	colorModulator: c_int,
	ditherScale: c_int,
	fogStart: c_int,
	fogEnd: c_int,
	fogColor: c_int,
} = undefined;

var transparentPipeline: graphics.Pipeline = undefined;
var transparentUniforms: struct {
	cloudOffset: c_int,
	cloudScale: c_int,
	darknessColorModifier: c_int,
	firstElement: c_int,
	colorModulator: c_int,
	ditherScale: c_int,
	fogStart: c_int,
	fogEnd: c_int,
	fogColor: c_int,
} = undefined;

var compositePipeline: graphics.Pipeline = undefined;

var faceVao: graphics.VertexArray = undefined;
var cubeVao: graphics.VertexArray = undefined;

var noiseLayerSsbo: graphics.SSBO = undefined;
var layerGroupingSsbo: graphics.SSBO = undefined;

var bayerTexture: c_uint = undefined;

/// Accumulation and revealage targets for the weighted blended transparency
/// pass. The depth attachment is borrowed from the world framebuffer each frame
/// so that terrain occludes the soft cloud shell correctly.
const TransparencyTarget = struct {
	frameBuffer: c_uint = 0,
	accum: c_uint = 0,
	revealage: c_uint = 0,
	width: u31 = 0,
	height: u31 = 0,

	fn init(self: *TransparencyTarget) void {
		c.glGenFramebuffers(1, &self.frameBuffer);
		c.glGenTextures(1, &self.accum);
		c.glGenTextures(1, &self.revealage);
		for ([_]c_uint{self.accum, self.revealage}) |texture| {
			c.glBindTexture(c.GL_TEXTURE_2D, texture);
			c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
			c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
			c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
			c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
		}
	}

	fn deinit(self: *TransparencyTarget) void {
		c.glDeleteTextures(1, &self.accum);
		c.glDeleteTextures(1, &self.revealage);
		c.glDeleteFramebuffers(1, &self.frameBuffer);
	}

	fn updateSize(self: *TransparencyTarget, width: u31, height: u31) void {
		if (self.width == width and self.height == height) return;
		self.width = width;
		self.height = height;
		c.glBindTexture(c.GL_TEXTURE_2D, self.accum);
		c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, width, height, 0, c.GL_RGBA, c.GL_FLOAT, null);
		c.glBindTexture(c.GL_TEXTURE_2D, self.revealage);
		c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8, width, height, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, null);
	}

	/// Binds the target with the world depth buffer attached, cleared and ready
	/// for accumulation.
	fn bindForAccumulation(self: *TransparencyTarget, depthTexture: c_uint) void {
		c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.frameBuffer);
		c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.accum, 0);
		c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT1, c.GL_TEXTURE_2D, self.revealage, 0);
		c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_DEPTH_ATTACHMENT, c.GL_TEXTURE_2D, depthTexture, 0);
		const attachments = [_]c_uint{c.GL_COLOR_ATTACHMENT0, c.GL_COLOR_ATTACHMENT1};
		c.glDrawBuffers(2, &attachments);

		// Blending is already configured by the pipeline, so clear with it off.
		c.glDisable(c.GL_BLEND);
		c.glDisable(c.GL_SCISSOR_TEST);
		c.glClearBufferfv(c.GL_COLOR, 0, &[4]f32{0, 0, 0, 0});
		c.glClearBufferfv(c.GL_COLOR, 1, &[4]f32{1, 1, 1, 1});
	}

	fn bindTextures(self: *const TransparencyTarget) void {
		c.glActiveTexture(c.GL_TEXTURE0 + accumTextureUnit);
		c.glBindTexture(c.GL_TEXTURE_2D, self.accum);
		c.glActiveTexture(c.GL_TEXTURE0 + revealageTextureUnit);
		c.glBindTexture(c.GL_TEXTURE_2D, self.revealage);
	}
};

var transparencyTarget: TransparencyTarget = .{};

/// The noise domain is offset along a slow circle rather than translated, which
/// keeps the clouds drifting without the offset ever growing without bound. One
/// full turn takes a little under an hour, so the drift direction changes only
/// very gradually.
var scrollAngle: f64 = 0;
const scrollRadius = 100.0;
const scrollRadiansPerSecond = 0.002;

var initialized = false;
/// The settings the current mesh generator was built for. Changing any of them
/// changes the chunk layout or the compute shader, so it has to be rebuilt.
var activeQuality: settings.CloudQuality = undefined;
var activeTransparency: bool = undefined;
var activeShading: bool = undefined;

// MARK: init

pub fn init() void {
	opaquePipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/clouds/clouds.vert",
		"assets/cubyz/shaders/clouds/clouds.frag",
		"",
		&opaqueUniforms,
		CloudVertex,
		.{
			.rasterState = .{.cullMode = .none},
			.depthStencilState = .{.depthTest = true, .depthWrite = true},
			.blendState = .{.attachments = &.{.noBlending}, .formats = &.{.world}},
		},
	);
	transparentPipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/clouds/clouds_transparent.vert",
		"assets/cubyz/shaders/clouds/clouds_transparent.frag",
		"",
		&transparentUniforms,
		CloudVertex,
		.{
			.rasterState = .{.cullMode = .none},
			.depthStencilState = .{.depthTest = true, .depthWrite = false},
			.blendState = .{
				.attachments = &.{
					// Accumulation is additive, revealage multiplies down.
					.{
						.srcColorBlendFactor = .one,
						.dstColorBlendFactor = .one,
						.colorBlendOp = .add,
						.srcAlphaBlendFactor = .one,
						.dstAlphaBlendFactor = .one,
						.alphaBlendOp = .add,
					},
					.{
						.srcColorBlendFactor = .zero,
						.dstColorBlendFactor = .oneMinusSrcColor,
						.colorBlendOp = .add,
						.srcAlphaBlendFactor = .zero,
						.dstAlphaBlendFactor = .oneMinusSrcAlpha,
						.alphaBlendOp = .add,
					},
				},
				.formats = &.{.{.custom = c.VK_FORMAT_R16G16B16A16_SFLOAT}, .{.custom = c.VK_FORMAT_R8_UNORM}},
			},
		},
	);
	compositePipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/clouds/clouds_composite.vert",
		"assets/cubyz/shaders/clouds/clouds_composite.frag",
		"",
		null,
		graphics.draw.SimpleVertex2D,
		.{
			.rasterState = .{.cullMode = .none},
			.depthStencilState = .{.depthTest = false, .depthWrite = false},
			.blendState = .{.attachments = &.{.alphaBlending}, .formats = &.{.world}},
			.inputAssemblyState = .{.topology = .triangleStrip},
		},
	);

	// The base face is the -X quad; the vertex shader rotates it onto the other
	// five directions.
	faceVao = .init(CloudVertex, &.{
		.{.pos = .{-1, -1, 1}},
		.{.pos = .{-1, -1, -1}},
		.{.pos = .{-1, 1, -1}},
		.{.pos = .{-1, 1, 1}},
	}, &.{0, 1, 2, 0, 2, 3});

	cubeVao = .init(CloudVertex, &.{
		.{.pos = .{-1, -1, -1}},
		.{.pos = .{1, -1, -1}},
		.{.pos = .{1, 1, -1}},
		.{.pos = .{-1, 1, -1}},
		.{.pos = .{1, -1, 1}},
		.{.pos = .{1, 1, 1}},
		.{.pos = .{-1, 1, 1}},
		.{.pos = .{-1, -1, 1}},
	}, &.{
		0, 1, 2, 0, 2, 3,
		4, 7, 6, 4, 6, 5,
		7, 0, 3, 7, 3, 6,
		1, 4, 5, 1, 5, 2,
		1, 0, 7, 1, 7, 4,
		5, 6, 3, 5, 3, 2,
	});

	initBayerMatrix();
	transparencyTarget.init();

	uploadCloudTypes();

	activeQuality = settings.cloudQuality;
	activeTransparency = settings.cloudTransparency;
	activeShading = settings.cloudShading;
	mesh.init(activeQuality, activeTransparency);
	initialized = true;
}

pub fn deinit() void {
	if (initialized) mesh.deinit();
	initialized = false;
	layerGroupingSsbo.deinit();
	noiseLayerSsbo.deinit();
	transparencyTarget.deinit();
	c.glDeleteTextures(1, &bayerTexture);
	cubeVao.deinit();
	faceVao.deinit();
	compositePipeline.deinit();
	transparentPipeline.deinit();
	opaquePipeline.deinit();
}

fn uploadCloudTypes() void {
	var layers: []CloudType.GpuNoiseLayer = undefined;
	var groups: []CloudType.GpuLayerGroup = undefined;
	CloudType.packForGpu(main.stackAllocator, &layers, &groups);
	defer main.stackAllocator.free(layers);
	defer main.stackAllocator.free(groups);

	noiseLayerSsbo = .initStatic(CloudType.GpuNoiseLayer, layers);
	layerGroupingSsbo = .initStatic(CloudType.GpuLayerGroup, groups);
}

pub fn bindCloudTypeBuffers() void {
	noiseLayerSsbo.bind(bindings.noiseLayers);
	layerGroupingSsbo.bind(bindings.layerGroupings);
}

/// Standard recursive ordered dither matrix, used to fade chunks in without
/// making them translucent.
fn initBayerMatrix() void {
	var current: [bayerMatrixSize][bayerMatrixSize]u32 = undefined;
	current[0][0] = 0;
	var n: usize = 1;
	while (n < bayerMatrixSize) : (n *= 2) {
		var next: [bayerMatrixSize][bayerMatrixSize]u32 = undefined;
		for (0..n) |y| {
			for (0..n) |x| {
				const base = 4*current[y][x];
				next[y][x] = base;
				next[y][x + n] = base + 2;
				next[y + n][x] = base + 3;
				next[y + n][x + n] = base + 1;
			}
		}
		current = next;
	}

	var pixels: [bayerMatrixSize*bayerMatrixSize]u8 = undefined;
	const total = bayerMatrixSize*bayerMatrixSize;
	for (0..bayerMatrixSize) |y| {
		for (0..bayerMatrixSize) |x| {
			pixels[y*bayerMatrixSize + x] = @intCast(current[y][x]*255/total);
		}
	}

	c.glGenTextures(1, &bayerTexture);
	c.glBindTexture(c.GL_TEXTURE_2D, bayerTexture);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
	c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
	c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
	c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8, bayerMatrixSize, bayerMatrixSize, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &pixels);
	c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);
}

// MARK: coordinate helpers

/// Converts a block position into cloud space, with Z relative to the cloud layer.
pub fn toCloudSpace(playerPos: Vec3d) Vec3d {
	return .{
		playerPos[0]/cloudScale,
		playerPos[1]/cloudScale,
		(playerPos[2] - settings.cloudHeight)/cloudScale,
	};
}

pub fn heightAbovePlayer(playerPos: Vec3d) f32 {
	return @floatCast(settings.cloudHeight - playerPos[2]);
}

/// Wraps the noise sample origin so that f32 keeps enough precision for the
/// finest noise layers even millions of blocks from the world origin.
pub fn wrapNoiseOrigin(gridOrigin: Vec2d) Vec2f {
	return .{
		@floatCast(@mod(gridOrigin[0], noiseWrap)),
		@floatCast(@mod(gridOrigin[1], noiseWrap)),
	};
}

/// Distance at which clouds have fully faded into the sky, in blocks.
pub fn fogEnd() f32 {
	return @max(mesh.maxRadius()*cloudScale, 2867);
}

fn fogStart() f32 {
	return fogEnd()/4;
}

/// Vertical extent of the whole cloud volume relative to the player, in blocks.
/// Used for frustum culling before the exact heights of a chunk are known.
pub fn globalHeightBoundsInBlocks() struct { min: f32, max: f32 } {
	const bounds = CloudType.globalHeightBounds();
	const playerPos = game.Player.getEyePosBlocking();
	const base = heightAbovePlayer(playerPos);
	return .{.min = base + bounds.min*cloudScale, .max = base + bounds.max*cloudScale};
}

// MARK: per frame update

/// Advances the wind and runs this frame's share of mesh generation. Must be
/// called before `render`.
pub fn prepare(frustum: *const main.renderer.Frustum, playerPos: Vec3d, deltaTime: f64) void {
	if (!settings.clouds) return;
	if (settings.cloudQuality != activeQuality or settings.cloudTransparency != activeTransparency or settings.cloudShading != activeShading) {
		rebuild();
	}
	if (!initialized) return;

	const paused = if (game.world) |world| world.paused else true;
	if (!paused) {
		scrollAngle += deltaTime*scrollRadiansPerSecond*settings.cloudSpeed;
		// The formations belong to the server; this only smooths their motion
		// between the snapshots it sends.
		regions.advance(@floatCast(deltaTime));
	}
	mesh.advanceFade(deltaTime);

	const scroll = Vec3f{
		@floatCast(@cos(scrollAngle)*scrollRadius),
		@floatCast(@sin(scrollAngle)*scrollRadius),
		0,
	};
	mesh.generate(frustum, playerPos, scroll);
}

fn rebuild() void {
	if (initialized) mesh.deinit();
	activeQuality = settings.cloudQuality;
	activeTransparency = settings.cloudTransparency;
	activeShading = settings.cloudShading;
	mesh.init(activeQuality, activeTransparency);
	initialized = true;
}

// MARK: rendering

/// Colour the clouds fade into at the horizon. Using the sky colour hides the
/// edge of the generated area completely.
fn horizonColor() Vec3f {
	if (game.world) |world| return world.dayTime.fog.skyColor;
	return .{0.8, 0.8, 1};
}

/// Draws the opaque cloud surface into the currently bound world framebuffer,
/// then resolves the soft transparent shell on top of it.
pub fn render(frustum: *const main.renderer.Frustum, playerPos: Vec3d, ambientLight: Vec3f, worldDepthTexture: c_uint, width: u31, height: u31) void {
	if (!settings.clouds or !initialized) return;

	c.glActiveTexture(c.GL_TEXTURE0 + bayerTextureUnit);
	c.glBindTexture(c.GL_TEXTURE_2D, bayerTexture);

	const worldFrameBuffer = blk: {
		var current: c_int = 0;
		c.glGetIntegerv(c.GL_FRAMEBUFFER_BINDING, &current);
		break :blk @as(c_uint, @intCast(current));
	};

	renderOpaque(frustum, playerPos, ambientLight);

	if (mesh.transparencyEnabled()) {
		renderTransparent(frustum, playerPos, ambientLight, worldDepthTexture, worldFrameBuffer, width, height);
	}
}

fn renderOpaque(frustum: *const main.renderer.Frustum, playerPos: Vec3d, ambientLight: Vec3f) void {
	const renderables = mesh.collectRenderable(main.stackAllocator, frustum, playerPos, .solid);
	defer main.stackAllocator.free(renderables);
	if (renderables.len == 0) return;

	opaquePipeline.bind(null);
	mesh.bindOpaquePool();
	faceVao.bind();

	const tint = horizonColor();
	c.glUniform1f(opaqueUniforms.cloudScale, cloudScale);
	c.glUniform1f(opaqueUniforms.lightPower, diffuseLightPower);
	c.glUniform1f(opaqueUniforms.ambientLight, diffuseAmbientLight);
	c.glUniform3fv(opaqueUniforms.darknessColorModifier, 1, @ptrCast(&darknessColorModifier));
	c.glUniform1i(opaqueUniforms.useNormals, if (settings.cloudNormals) 1 else 0);
	c.glUniform1f(opaqueUniforms.ditherScale, ditherScale);
	c.glUniform1f(opaqueUniforms.fogStart, fogStart());
	c.glUniform1f(opaqueUniforms.fogEnd, fogEnd());
	c.glUniform3fv(opaqueUniforms.fogColor, 1, @ptrCast(&tint));

	for (renderables) |chunk| {
		c.glUniform3fv(opaqueUniforms.cloudOffset, 1, @ptrCast(&chunk.cloudOffset));
		c.glUniform1i(opaqueUniforms.firstElement, @intCast(chunk.firstElement));
		c.glUniform4f(opaqueUniforms.colorModulator, ambientLight[0], ambientLight[1], ambientLight[2], chunk.alpha);
		c.glDrawElementsInstanced(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_INT, null, @intCast(chunk.elementCount));
	}
}

fn renderTransparent(
	frustum: *const main.renderer.Frustum,
	playerPos: Vec3d,
	ambientLight: Vec3f,
	worldDepthTexture: c_uint,
	worldFrameBuffer: c_uint,
	width: u31,
	height: u31,
) void {
	const renderables = mesh.collectRenderable(main.stackAllocator, frustum, playerPos, .shell);
	defer main.stackAllocator.free(renderables);
	if (renderables.len == 0) return;

	transparencyTarget.updateSize(width, height);
	transparencyTarget.bindForAccumulation(worldDepthTexture);
	c.glViewport(0, 0, width, height);

	transparentPipeline.bind(null);
	mesh.bindTransparentPool();
	cubeVao.bind();

	const tint = horizonColor();
	c.glUniform1f(transparentUniforms.cloudScale, cloudScale);
	c.glUniform3fv(transparentUniforms.darknessColorModifier, 1, @ptrCast(&darknessColorModifier));
	c.glUniform1f(transparentUniforms.ditherScale, ditherScale);
	c.glUniform1f(transparentUniforms.fogStart, fogStart());
	c.glUniform1f(transparentUniforms.fogEnd, fogEnd());
	c.glUniform3fv(transparentUniforms.fogColor, 1, @ptrCast(&tint));

	for (renderables) |chunk| {
		c.glUniform3fv(transparentUniforms.cloudOffset, 1, @ptrCast(&chunk.cloudOffset));
		c.glUniform1i(transparentUniforms.firstElement, @intCast(chunk.firstElement));
		c.glUniform4f(transparentUniforms.colorModulator, ambientLight[0], ambientLight[1], ambientLight[2], chunk.alpha);
		c.glDrawElementsInstanced(c.GL_TRIANGLES, 36, c.GL_UNSIGNED_INT, null, @intCast(chunk.elementCount));
	}

	// Detach the borrowed depth buffer before writing to the world again.
	c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_DEPTH_ATTACHMENT, c.GL_TEXTURE_2D, 0, 0);
	c.glBindFramebuffer(c.GL_FRAMEBUFFER, worldFrameBuffer);

	transparencyTarget.bindTextures();
	compositePipeline.bind(null);
	graphics.draw.rectVao.bind();
	c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
}

// MARK: queries

/// What weather the formations overhead bring at a block position, and how
/// strongly. This ignores the terrain and the biome; the rain renderer applies
/// those on top.
pub fn precipitationAt(pos: Vec3d) weather.Precipitation {
	if (!initialized) return .none;
	const cloudPos = toCloudSpace(pos);
	return weather.precipitationAt(regions.active.items, .{cloudPos[0], cloudPos[1]});
}

/// How much the formations overhead dim what is underneath them, from 0 for a
/// clear sky to 1 for the heart of a thunderstorm.
pub fn stormDarkeningAt(pos: Vec3d) f32 {
	if (!initialized) return 0;
	const cloudPos = toCloudSpace(pos);
	const sample = regions.sampleAt(.{cloudPos[0], cloudPos[1]});
	return CloudType.get(sample.typeIndex).storminess*sample.presence;
}

/// World Z of the underside of the clouds above a position, which is as high as
/// rain can start. Falls back to the cloud layer itself where there is nothing
/// overhead.
pub fn cloudBaseAt(pos: Vec3d) f64 {
	if (!initialized) return settings.cloudHeight;
	const cloudPos = toCloudSpace(pos);
	const sample = regions.sampleAt(.{cloudPos[0], cloudPos[1]});
	return settings.cloudHeight + @as(f64, CloudType.get(sample.typeIndex).minHeight())*cloudScale;
}
