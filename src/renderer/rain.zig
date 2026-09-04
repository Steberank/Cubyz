//! Rain.
//!
//! Rather than simulating individual drops, one instanced quad is drawn per
//! ground column around the player, textured with rain streaks that scroll
//! downwards. That is what makes dense rain affordable: the whole effect is a
//! single draw call of a few hundred quads and nothing is stepped on the CPU.
//!
//! Splashes are the exception. Because there are no real drops there are no real
//! impacts either, so points on the surface are sampled at a rate proportional
//! to the rain's strength and a short lived particle burst is spawned there. The
//! eye cannot follow one drop to its impact, so this is indistinguishable from
//! tracking them for real.
//!
//! Whether it rains at all comes from the server's cloud formations; the biome
//! the player stands in can veto it.

const std = @import("std");

const main = @import("main");
const game = main.game;
const graphics = main.graphics;
const random = main.random;
const settings = main.settings;
const vec = main.vec;
const Vec2f = vec.Vec2f;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;

const c = @import("c");

const clouds = @import("clouds.zig");
const mesh_storage = @import("mesh_storage.zig");

/// Radius of the rain volume in columns.
const gridRadius = 20;
const gridSize = 2*gridRadius + 1;
/// Columns this close are scanned for their surface, which is what splashes need
/// and what stops rain falling through a roof. Further out the terrain occludes
/// the rain anyway, so the scan is skipped and the column is assumed to be open.
const scanRadius = 16;
/// The column cache is a ring buffer indexed by the low bits of a column's
/// coordinates, so its size has to be a power of two larger than `gridSize`.
const cacheSize = 64;
const cacheMask = cacheSize - 1;

/// How many columns are rescanned per frame. The whole grid refreshes in about a
/// dozen frames, which is fast enough that the rain keeps up with the player.
const refreshPerFrame = 140;
/// How long a scanned column stays trusted. Terrain and light change, so it has
/// to expire; this also sets how quickly a placed torch reaches the rain.
const columnLifetime = 0.75;
/// How far down a column is scanned looking for its surface. The light map puts
/// the start of the scan just above the terrain, so the shorter limit is enough
/// unless it is unavailable and the scan has to start at the camera.
const scanDepthFromLightMap = 40;
const maxScanDepth = 96;
const chunkHeight = main.chunk.chunkSize;

/// Vertical extent of the rain volume relative to the camera, in blocks.
const rainAbove = 14.0;
const rainBelow = 12.0;

/// Half the width of a column's quad, in blocks. Together with the 32 pixel wide
/// texture this makes a one pixel drop about 2 cm across.
const streakHalfWidth = 0.3;
/// Texture repeats per block of height. The texture is 128 pixels tall, so this
/// makes a four pixel drop about 40 cm long and only repeats every 13 blocks.
const streakRepeatsPerBlock = 1.0/12.8;
/// Texture repeats scrolled through per second.
const fallSpeed = 1.1;
/// Only a slight spread, because drops falling at visibly different speeds looks
/// wrong. What breaks up the regularity is the per column starting height.
const fallSpeedVariation = 0.08;
/// Columns are nudged off their grid cell by up to this much, so that the drops
/// are spread over a range of distances instead of landing on tidy rows.
const columnJitter = 0.38;
const rainColor = Vec3f{0.46, 0.63, 0.88};
/// How much of the drops' brightness a full thunderstorm takes away.
const stormDarkening = 0.45;
/// How much the streaks lean, in blocks of horizontal offset per block of height.
const windSlant = 0.18;
/// Rain stays at full strength out to this fraction of the grid radius.
const fadeStartFraction = 0.72;

/// Splashes per second at full intensity.
const maxSplashesPerSecond = 1280.0;
/// How far out splashes land. This is well past `scanRadius` because a splash
/// only needs one column scanned on demand, which is far cheaper than keeping
/// the whole area cached.
const splashRadius = 32;
/// How quickly the rain fades in and out when the weather changes, per second.
const intensityChangeRate = 0.4;

const Surface = enum { solid, water };

const Column = struct {
	x: i32 = std.math.minInt(i32),
	y: i32 = std.math.minInt(i32),
	/// Age of the scan in seconds, or `null` when this slot was never filled.
	age: ?f32 = null,
	/// False when something solid sits above the camera, which is how being
	/// indoors is detected.
	exposed: bool = false,
	/// Top of the surface the rain lands on.
	groundZ: f64 = 0,
	surface: Surface = .solid,
	/// Sky and block light just above the surface, sampled with the scan rather
	/// than every frame. A torch therefore takes up to `columnLifetime` to show
	/// up in the rain, which is not noticeable.
	light: [6]u8 = @splat(0),
	hasLight: bool = false,

	/// Whether this slot actually describes the given column. Walking around
	/// invalidates slots faster than they can be rescanned, so the renderer has
	/// to cope with not knowing yet.
	fn describes(self: Column, x: i32, y: i32) bool {
		return self.x == x and self.y == y and self.age != null;
	}
};

/// Layout of `RainColumn` in `rain.vert`.
const GpuColumn = extern struct {
	offset: [2]f32,
	bottom: f32,
	top: f32,
	phase: [2]f32,
	speed: f32,
	padding: f32 = 0,
	/// `vec4` in the shader, since std430 aligns a `vec3` to 16 bytes anyway.
	light: [4]f32,
};

comptime {
	std.debug.assert(@sizeOf(GpuColumn) == 48);
}

const RainVertex = extern struct {
	corner: [2]f32,

	pub const attributeDescriptions: []const c.VkVertexInputAttributeDescription = &.{
		.{
			.location = 0,
			.format = c.VK_FORMAT_R32G32_SFLOAT,
			.offset = @offsetOf(@This(), "corner"),
		},
	};
};

var pipeline: graphics.Pipeline = undefined;
var uniforms: struct {
	rightVector: c_int,
	halfWidth: c_int,
	time: c_int,
	repeatsPerBlock: c_int,
	fadeRange: c_int,
	slant: c_int,
	rainColor: c_int,
	intensity: c_int,
	screenSize: c_int,
} = undefined;

var quadVao: graphics.VertexArray = undefined;
var columnSsbo: graphics.SSBO = undefined;
var rainTexture: graphics.Texture = undefined;

var columns: [cacheSize*cacheSize]Column = @splat(.{});
var refreshCursor: usize = 0;

var intensity: f32 = 0;
/// Seconds of rain, which the shader turns into per column scrolling.
var scroll: f64 = 0;
var splashDebt: f32 = 0;
var splashSeed: u64 = 0x5a1b_1a54;

var splashEmitter: main.particles.Emitter = undefined;
var rippleEmitter: main.particles.Emitter = undefined;
/// Which world the emitters were resolved against. Particle types are registered
/// per world, so their indices are only valid for the world that produced them.
var emitterWorld: ?*game.World = null;
var emittersResolved = false;

pub fn init() void {
	pipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/rain/rain.vert",
		"assets/cubyz/shaders/rain/rain.frag",
		"",
		&uniforms,
		RainVertex,
		.{
			.rasterState = .{.cullMode = .none},
			// Drawn onto the finished frame, which has no depth buffer, so the
			// fragment shader tests the scene depth itself.
			.depthStencilState = .{.depthTest = false, .depthWrite = false},
			.blendState = .{.attachments = &.{.alphaBlending}, .formats = &.{.swapChain}},
			.inputAssemblyState = .{.topology = .triangleStrip},
		},
	);

	quadVao = .init(RainVertex, &.{
		.{.corner = .{-1, 0}},
		.{.corner = .{-1, 1}},
		.{.corner = .{1, 0}},
		.{.corner = .{1, 1}},
	}, null);

	columnSsbo = .initDynamicSize(GpuColumn, gridSize*gridSize);
	rainTexture = .initFromFile("assets/cubyz/rain/rain.png");
}

pub fn deinit() void {
	rainTexture.deinit();
	columnSsbo.deinit();
	quadVao.deinit();
	pipeline.deinit();
}

/// Emitters resolve particle type ids, which only exist once a world's assets
/// are loaded, so they cannot be built during startup. Loading another world
/// re-registers the types, so they have to be resolved again.
fn ensureEmitters() void {
	if (emittersResolved and emitterWorld == game.world) return;
	emittersResolved = true;
	emitterWorld = game.world;
	// Thrown straight up rather than scattered. Droplets do not collide, so any
	// that headed downwards would sink into the block they landed on and be
	// rendered with its light, which is none. Gravity brings them back down
	// within their lifetime anyway, and the speed range supplies the variety.
	splashEmitter = .init("cubyz:rain_splash", false, .{.point = .{}}, .{
		.speed = .init(1.5, 3.0),
		.lifeTime = .init(0.12, 0.24),
		.randomizeRotation = false,
	}, .{.direction = .{0, 0, 1}});
	rippleEmitter = .init("cubyz:rain_ripple", false, .{.point = .{}}, .{
		.speed = .init(0, 0),
		.lifeTime = .init(0.3, 0.45),
		.randomizeRotation = false,
	}, .{.direction = .{0, 0, 1}});
}

pub fn reset() void {
	intensity = 0;
	splashDebt = 0;
	columns = @splat(.{});
	emittersResolved = false;
}

// MARK: intensity

/// Averages a group of opposing biome properties into a single value. Biomes may
/// set several flags at once to sit between two extremes.
fn propertyBlend(low: bool, mid: bool, high: bool) f32 {
	var sum: f32 = 0;
	var count: f32 = 0;
	if (low) {
		sum += 0;
		count += 1;
	}
	if (mid) {
		sum += 0.5;
		count += 1;
	}
	if (high) {
		sum += 1;
		count += 1;
	}
	if (count == 0) return 0.5;
	return sum/count;
}

/// How much of the formations' rain actually falls here. The client only knows
/// the biome the player stands in, which is plenty: the rain volume is a handful
/// of blocks wide.
fn biomeFactor() f32 {
	const world = game.world orelse return 1;
	const properties = world.playerBiome.load(.monotonic).properties;

	// Only outright deserts stay dry. Cold biomes ought to get snow instead, but
	// until that exists rain is better than nothing.
	// TODO: Turn this into snow in cold biomes.
	const wetness = propertyBlend(properties.dry, properties.neitherWetNorDry, properties.wet);
	return std.math.clamp(0.25 + wetness*1.5, 0, 1);
}

fn targetIntensity(playerPos: Vec3d) f32 {
	if (!settings.rain) return 0;
	const precipitation = clouds.precipitationAt(playerPos);
	if (precipitation.weather == .none) return 0;
	return precipitation.amount*biomeFactor();
}

// MARK: column cache

fn slotOf(x: i32, y: i32) *Column {
	const xi: usize = @intCast(x & cacheMask);
	const yi: usize = @intCast(y & cacheMask);
	return &columns[xi*cacheSize + yi];
}

/// Walks a column downwards to find the surface rain would land on, and whether
/// anything covers the camera. The first solid or liquid block seen from above is
/// the surface; if it is above the camera then the camera is underneath it.
fn scanColumn(x: i32, y: i32, cameraZ: f64, withinScanRadius: bool) Column {
	var result: Column = .{.x = x, .y = y, .age = 0};

	if (!withinScanRadius) {
		// Too far away for the surface to matter. Nothing splashes there and the
		// terrain in between hides anything that would be wrong.
		result.groundZ = -std.math.inf(f64);
		result.exposed = true;
		return result;
	}

	// The light map records roughly where the sky starts, which is a good place
	// to begin. Buildings can rise above it, so never start below the camera.
	var depth: i32 = maxScanDepth;
	const mapTop: f64 = blk: {
		if (mesh_storage.getLightMapPiece(x, y, 1)) |piece| {
			depth = scanDepthFromLightMap;
			break :blk @floatFromInt(piece.getHeight(x, y));
		}
		break :blk cameraZ + rainAbove;
	};
	const startZ: i32 = @intFromFloat(@floor(@max(mapTop, cameraZ + rainAbove)));

	var z = startZ;
	var missing: i32 = 0;
	const lowest = startZ - depth;
	while (z > lowest) : (z -= 1) {
		const block = mesh_storage.getBlockFromRenderThread(x, y, z) orelse {
			// Chunks are a cube of blocks, so a run of misses this long means
			// the terrain here simply is not loaded yet. That is the norm while
			// a world is still streaming in, and scanning the rest of the column
			// would be the same number of wasted lookups again.
			missing += 1;
			if (missing > chunkHeight) break;
			continue;
		};
		missing = 0;
		const isFluid = block.hasTag(.fluid);
		if (!block.collide() and !isFluid) continue;

		result.groundZ = @floatFromInt(z + 1);
		result.surface = if (isFluid) .water else .solid;
		// Whatever is found first from above is a roof if it is over the camera,
		// and the ground the rain lands on otherwise.
		result.exposed = result.groundZ <= cameraZ + 1;
		if (mesh_storage.getLight(x, y, z + 1)) |light| {
			result.light = light;
			result.hasLight = true;
		}
		return result;
	}

	// Nothing within reach, which is what flying high above the terrain looks
	// like. It still rains, there is just nothing close enough to splash on.
	result.groundZ = -std.math.inf(f64);
	result.exposed = true;
	return result;
}

/// Rescans a slice of the grid each frame and ages the rest.
fn refreshColumns(playerPos: Vec3d, deltaTime: f32) void {
	const centerX: i32 = @intFromFloat(@floor(playerPos[0]));
	const centerY: i32 = @intFromFloat(@floor(playerPos[1]));

	for (&columns) |*column| {
		if (column.age) |*age| age.* += deltaTime;
	}

	const total = gridSize*gridSize;
	for (0..@min(refreshPerFrame, total)) |_| {
		const index = refreshCursor%total;
		refreshCursor +%= 1;

		const dx = @as(i32, @intCast(index/gridSize)) - gridRadius;
		const dy = @as(i32, @intCast(index%gridSize)) - gridRadius;
		const x = centerX + dx;
		const y = centerY + dy;

		const slot = slotOf(x, y);
		const stale = !slot.describes(x, y) or slot.age.? > columnLifetime;
		if (stale) slot.* = scanColumn(x, y, playerPos[2], dx*dx + dy*dy <= scanRadius*scanRadius);
	}
}

// MARK: splashes

fn spawnSplashes(playerPos: Vec3d, deltaTime: f32) void {
	splashDebt += maxSplashesPerSecond*intensity*deltaTime;
	const wanted: u32 = @intFromFloat(@floor(splashDebt));
	if (wanted == 0) return;
	splashDebt -= @floatFromInt(wanted);

	ensureEmitters();

	const centerX: i32 = @intFromFloat(@floor(playerPos[0]));
	const centerY: i32 = @intFromFloat(@floor(playerPos[1]));

	const span = 2*splashRadius + 1;
	for (0..@min(wanted, 96)) |_| {
		const x = centerX + @as(i32, @intCast(random.nextIntBounded(u32, &splashSeed, span))) - splashRadius;
		const y = centerY + @as(i32, @intCast(random.nextIntBounded(u32, &splashSeed, span))) - splashRadius;

		// A splash needs a surface to land on, so the column is scanned on the
		// spot when the cache does not already know it. That is only a handful
		// of scans per frame, which is what lets splashes reach further out
		// than the cached grid does.
		const cached = slotOf(x, y).*;
		const column = if (cached.describes(x, y)) cached else scanColumn(x, y, playerPos[2], true);
		if (!column.exposed or !std.math.isFinite(column.groundZ)) continue;
		if (playerPos[2] - column.groundZ > maxScanDepth) continue;

		// Lifted clear of the surface so the light lookup lands in the air block
		// above it rather than inside the solid one, which would come out black.
		const pos = Vec3d{
			@as(f64, @floatFromInt(x)) + random.nextDouble(&splashSeed),
			@as(f64, @floatFromInt(y)) + random.nextDouble(&splashSeed),
			column.groundZ + 0.12,
		};
		switch (column.surface) {
			.solid => splashEmitter.spawnParticles(pos, 2),
			.water => rippleEmitter.spawnParticles(pos, 1),
		}
	}
}

/// A drop falls in the open for most of its length, so it is never as dark as
/// the ground it lands on. Without this floor a column whose light is unknown
/// would render its drops black.
const skyLightFloor = 0.4;

/// Combines a column's cached sky and block light the same way the chunk and
/// particle shaders do, so that a torch lights the rain falling past it.
fn litColor(column: Column, ambientLight: Vec3f) Vec3f {
	const floor = ambientLight*@as(Vec3f, @splat(skyLightFloor));
	if (!column.hasLight) return ambientLight;
	const raw = column.light;
	const scale: Vec3f = @splat(1.0/255.0);
	const sun = Vec3f{@floatFromInt(raw[0]), @floatFromInt(raw[1]), @floatFromInt(raw[2])}*scale*ambientLight;
	const block = Vec3f{@floatFromInt(raw[3]), @floatFromInt(raw[4]), @floatFromInt(raw[5])}*scale;
	const combined = @min(@sqrt(sun*sun + block*block), @as(Vec3f, @splat(1)));
	return @max(combined, floor);
}

// MARK: rendering

/// Advances the rain and rebuilds the column cache. Must run before `render`.
pub fn update(playerPos: Vec3d, deltaTime: f64) void {
	const dt: f32 = @floatCast(deltaTime);
	const paused = if (game.world) |world| world.paused else true;

	// Ease towards the target so passing weather fronts arrive and leave
	// gradually instead of switching on.
	const target = if (paused) intensity else targetIntensity(playerPos);
	intensity += std.math.clamp(target - intensity, -intensityChangeRate*dt, intensityChangeRate*dt);

	if (intensity <= 0.001) {
		intensity = 0;
		return;
	}

	if (!paused) scroll += deltaTime;
	refreshColumns(playerPos, dt);
	if (!paused) spawnSplashes(playerPos, dt);
}

/// Draws the rain over the finished frame.
///
/// This runs after the deferred pass on purpose. Rain is a close range effect,
/// and it does not write depth, so leaving it in the world framebuffer would
/// have the deferred pass fog it by the distance of the terrain behind it. In a
/// biome with heavy fog that made drops a couple of metres away almost
/// invisible. The scene depth is sampled in the shader instead, so terrain still
/// occludes the rain.
pub fn render(playerPos: Vec3d, ambientLight: Vec3f) void {
	if (intensity <= 0) return;

	const centerX: i32 = @intFromFloat(@floor(playerPos[0]));
	const centerY: i32 = @intFromFloat(@floor(playerPos[1]));

	var gpuColumns: [gridSize*gridSize]GpuColumn = undefined;
	var count: usize = 0;

	// Rain starts at the underside of the clouds, so flying above them leaves
	// nothing to draw.
	const cloudBase = clouds.cloudBaseAt(playerPos) - playerPos[2];
	const top: f32 = @floatCast(@min(rainAbove, cloudBase));
	if (top <= -rainBelow) return;
	for (0..gridSize) |ix| {
		for (0..gridSize) |iy| {
			const x = centerX + @as(i32, @intCast(ix)) - gridRadius;
			const y = centerY + @as(i32, @intCast(iy)) - gridRadius;
			const slot = slotOf(x, y);
			// A column that has not been scanned yet still rains. Skipping it
			// would punch a hole in the rain that follows the player around.
			const known = slot.describes(x, y);
			if (known and !slot.exposed) continue;
			const groundZ = if (known) slot.groundZ else -std.math.inf(f64);

			// The streaks only span a band around the camera, so a column in a
			// deep valley does not turn into an enormous quad.
			const bottom: f32 = @floatCast(@max(groundZ - playerPos[2], -rainBelow));
			if (bottom >= top) continue;

			// All derived from the column's coordinates, so a column keeps its
			// own jitter, starting height and speed as the player walks past.
			var columnSeed = random.initSeed2D(0x0dd_d10b, .{x, y});
			const jitter = Vec2f{
				random.nextFloatSigned(&columnSeed)*columnJitter,
				random.nextFloatSigned(&columnSeed)*columnJitter,
			};
			gpuColumns[count] = .{
				.offset = .{
					@as(f32, @floatCast(@as(f64, @floatFromInt(x)) + 0.5 - playerPos[0])) + jitter[0],
					@as(f32, @floatCast(@as(f64, @floatFromInt(y)) + 0.5 - playerPos[1])) + jitter[1],
				},
				.bottom = bottom,
				.top = top,
				.phase = .{random.nextFloat(&columnSeed), random.nextFloat(&columnSeed)},
				.speed = fallSpeed*(1 + fallSpeedVariation*random.nextFloatSigned(&columnSeed)),
				.light = lightSample: {
					const lit = litColor(if (known) slot.* else .{}, ambientLight);
					break :lightSample .{lit[0], lit[1], lit[2], 1};
				},
			};
			count += 1;
		}
	}
	if (count == 0) return;

	columnSsbo.bufferSubData(GpuColumn, gpuColumns[0..count], count);
	columnSsbo.bind(30);

	// Widen the quads perpendicular to where the camera looks, so they face it
	// without ever leaning out of vertical.
	const forward = vec.rotateZ(Vec3f{0, 1, 0}, -game.camera.rotation[2]);
	const right = Vec2f{forward[1], -forward[0]};

	pipeline.bind(null);
	c.glActiveTexture(c.GL_TEXTURE6);
	rainTexture.bind();
	main.renderer.bindWorldDepthTexture(c.GL_TEXTURE4);

	var viewport: [4]c_int = undefined;
	c.glGetIntegerv(c.GL_VIEWPORT, &viewport);
	c.glUniform2f(uniforms.screenSize, @floatFromInt(viewport[2]), @floatFromInt(viewport[3]));

	c.glUniform2f(uniforms.rightVector, right[0], right[1]);
	c.glUniform1f(uniforms.halfWidth, streakHalfWidth);
	c.glUniform1f(uniforms.time, @floatCast(scroll));
	c.glUniform1f(uniforms.repeatsPerBlock, streakRepeatsPerBlock);
	c.glUniform2f(uniforms.fadeRange, gridRadius*fadeStartFraction, gridRadius);
	c.glUniform2f(uniforms.slant, right[0]*windSlant, right[1]*windSlant);
	// The sky and torch light are per column; this is only the storm dimming,
	// which applies to the whole volume.
	const darkening = 1 - stormDarkening*clouds.stormDarkeningAt(playerPos);
	const tint = rainColor*@as(Vec3f, @splat(darkening));
	c.glUniform3fv(uniforms.rainColor, 1, @ptrCast(&tint));
	c.glUniform1f(uniforms.intensity, intensity);

	quadVao.bind();
	c.glDrawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(count));
}

/// How hard it is currently raining where the player is, from 0 to 1.
pub fn currentIntensity() f32 {
	return intensity;
}

