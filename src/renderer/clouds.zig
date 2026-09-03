const std = @import("std");

const main = @import("main");
const graphics = main.graphics;
const random = main.random;
const vec = main.vec;
const Vec2f = vec.Vec2f;
const Vec3d = vec.Vec3d;
const Vec3f = vec.Vec3f;
const Vec4f = vec.Vec4f;

const c = @import("c");

const configPath = "assets/cubyz/clouds.txt";
const maxRegions = 280;
const maxTypes = 7;
const maxLayers = 28;
const maxSides = 4000000;
const localX: u32 = 8;
const localY: u32 = 4;
const localZ: u32 = 8;
const edgeFade: f32 = 180;
const rainThreshold: f32 = 0.15;
const rainFogMargin: f32 = 560;
const minRegionSeparation: f32 = 160;
const spawnAttempts = 28;
const blockFadeTime: f32 = 5;
const lodFadeTime: f32 = 0.5;
const lodFadeDelay: f32 = 0.5;
const stormCloudFadeTime: f32 = 35;
const gameDayTicks: i64 = 12000;
const reloadInterval: std.Io.Duration = .fromMilliseconds(500);

const CloudLod = struct {
	voxelSize: f32,
	gridX: u32,
	gridY: u32,
	gridZ: u32,
	innerRadius: f32,
	outerRadius: f32,
};

const cloudLods = [_]CloudLod{
	.{.voxelSize = 8, .gridX = 128, .gridY = 128, .gridZ = 136, .innerRadius = 0, .outerRadius = 448},
	.{.voxelSize = 16, .gridX = 192, .gridY = 192, .gridZ = 72, .innerRadius = 448, .outerRadius = 1408},
	.{.voxelSize = 32, .gridX = 192, .gridY = 192, .gridZ = 40, .innerRadius = 1408, .outerRadius = 2816},
	.{.voxelSize = 48, .gridX = 256, .gridY = 256, .gridZ = 28, .innerRadius = 2816, .outerRadius = 5632},
	.{.voxelSize = 64, .gridX = 384, .gridY = 384, .gridZ = 24, .innerRadius = 5632, .outerRadius = 11264},
};

const occupancyOffsets = blk: {
	var offsets: [cloudLods.len]u32 = undefined;
	var total: u32 = 0;
	for (cloudLods, 0..) |lod, i| {
		offsets[i] = total;
		total += lod.gridX*lod.gridY*lod.gridZ;
	}
	break :blk offsets;
};
const occupancyTotal = occupancyOffsets[cloudLods.len - 1] + cloudLods[cloudLods.len - 1].gridX*cloudLods[cloudLods.len - 1].gridY*cloudLods[cloudLods.len - 1].gridZ;

const GpuOccupancy = extern struct {
	key: u32,
	fade: f32,
	lodFade: f32,
	lodHold: f32 = 0,
};

pub const Weather = enum(u32) {
	none = 0,
	rain = 1,
	thunderstorm = 2,
};

const Config = struct {
	height: f32 = 512,
	speed: f32 = 100.0/1200.0,
	windX: f32 = 1,
	windY: f32 = 0,
	seed: u64 = 1,
	debug: f32 = 0,
};

const NoiseLayer = extern struct {
	height: f32,
	heightOffset: f32,
	fadeDistance: f32,
	scaleX: f32,
	scaleY: f32,
	scaleZ: f32,
	valueOffset: f32,
	valueScale: f32,
};

const LayerGroup = extern struct {
	startIndex: i32,
	endIndex: i32,
	storminess: f32,
	stormStart: f32,
	stormFadeDistance: f32,
	pad0: f32 = 0,
	pad1: f32 = 0,
	pad2: f32 = 0,
};

const GpuRegion = extern struct {
	posX: f32,
	posY: f32,
	radius: f32,
	stretch: f32,
	rotation: f32,
	typeIndex: f32,
	opacity: f32,
	pad1: f32 = 0,
};

const IndirectCommand = extern struct {
	count: u32 = 6,
	instanceCount: u32 = 0,
	first: u32 = 0,
	baseInstance: u32 = 0,
};

const CloudTypeDef = struct {
	id: []const u8,
	weather: Weather,
	storminess: f32,
	stormStart: f32,
	stormFadeDistance: f32,
	weight: f32,
	maxCount: u32,
	orderWeight: i32,
	radiusMin: f32,
	radiusMax: f32,
	speedMin: f32,
	speedMax: f32,
	stretchMin: f32,
	stretchMax: f32,
	existMin: f32,
	existMax: f32,
	growMin: f32,
	growMax: f32,
	movesToPlayer: bool,
	layers: []const NoiseLayer,
};

const Region = struct {
	typeIndex: u32,
	posX: f32,
	posY: f32,
	radius: f32,
	targetRadius: f32,
	stretch: f32,
	rotation: f32,
	velX: f32,
	velY: f32,
	maxSpeed: f32,
	age: f32,
	growTime: f32,
	existTime: f32,
	orderWeight: i32,
	fadeIn: f32,
	fadeOut: f32,
};

const DummyVertex = struct {
	pad: f32 = 0,
	pub const attributeDescriptions: []const c.VkVertexInputAttributeDescription = &.{};
};

const typeDefs = [_]CloudTypeDef{
	.{
		.id = "itty_bitty",
		.weather = .none,
		.storminess = 0.0,
		.stormStart = 0,
		.stormFadeDistance = 32,
		.weight = 12,
		.maxCount = 280,
		.orderWeight = 400,
		.radiusMin = 480,
		.radiusMax = 820,
		.speedMin = 8,
		.speedMax = 16,
		.stretchMin = 1,
		.stretchMax = 1,
		.existMin = 400,
		.existMax = 720,
		.growMin = 20,
		.growMax = 40,
		.movesToPlayer = false,
		.layers = &.{.{
			.height = 80,
			.heightOffset = 0,
			.fadeDistance = 24,
			.scaleX = 140,
			.scaleY = 140,
			.scaleZ = 48,
			.valueOffset = -0.8,
			.valueScale = 1,
		}},
	},
	.{
		.id = "small_cumulus",
		.weather = .none,
		.storminess = 0.1,
		.stormStart = 10,
		.stormFadeDistance = 16,
		.weight = 24,
		.maxCount = 280,
		.orderWeight = 500,
		.radiusMin = 560,
		.radiusMax = 980,
		.speedMin = 8,
		.speedMax = 15,
		.stretchMin = 1,
		.stretchMax = 1,
		.existMin = 420,
		.existMax = 760,
		.growMin = 5,
		.growMax = 5,
		.movesToPlayer = false,
		.layers = &.{.{
			.height = 520,
			.heightOffset = 0,
			.fadeDistance = 200,
			.scaleX = 380,
			.scaleY = 380,
			.scaleZ = 380,
			.valueOffset = -0.25,
			.valueScale = 1,
		}},
	},
	.{
		.id = "cumulus",
		.weather = .none,
		.storminess = 0.2,
		.stormStart = 16,
		.stormFadeDistance = 16,
		.weight = 34,
		.maxCount = 280,
		.orderWeight = 600,
		.radiusMin = 720,
		.radiusMax = 1280,
		.speedMin = 7,
		.speedMax = 14,
		.stretchMin = 1,
		.stretchMax = 1,
		.existMin = 480,
		.existMax = 840,
		.growMin = 5,
		.growMax = 5,
		.movesToPlayer = false,
		.layers = &.{
			.{
				.height = 720,
				.heightOffset = 0,
				.fadeDistance = 260,
				.scaleX = 480,
				.scaleY = 480,
				.scaleZ = 480,
				.valueOffset = -0.2,
				.valueScale = 1,
			},
			.{
				.height = 720,
				.heightOffset = 0,
				.fadeDistance = 240,
				.scaleX = 90,
				.scaleY = 90,
				.scaleZ = 90,
				.valueOffset = 0,
				.valueScale = 0.16,
			},
		},
	},
	.{
		.id = "stratocumulus",
		.weather = .none,
		.storminess = 0.5,
		.stormStart = 0,
		.stormFadeDistance = 160,
		.weight = 4,
		.maxCount = 280,
		.orderWeight = 700,
		.radiusMin = 4000,
		.radiusMax = 8000,
		.speedMin = 6,
		.speedMax = 12,
		.stretchMin = 1,
		.stretchMax = 1,
		.existMin = 400,
		.existMax = 720,
		.growMin = 28,
		.growMax = 50,
		.movesToPlayer = false,
		.layers = &.{
			.{
				.height = 720,
				.heightOffset = 0,
				.fadeDistance = 300,
				.scaleX = 560,
				.scaleY = 560,
				.scaleZ = 380,
				.valueOffset = 0.40,
				.valueScale = 1,
			},
			.{
				.height = 720,
				.heightOffset = 0,
				.fadeDistance = 280,
				.scaleX = 900,
				.scaleY = 900,
				.scaleZ = 500,
				.valueOffset = 0.2,
				.valueScale = 0.35,
			},
			.{
				.height = 720,
				.heightOffset = 0,
				.fadeDistance = 220,
				.scaleX = 85,
				.scaleY = 85,
				.scaleZ = 75,
				.valueOffset = 0,
				.valueScale = 0.08,
			},
		},
	},
	.{
		.id = "stratus",
		.weather = .rain,
		.storminess = 0.4,
		.stormStart = 0,
		.stormFadeDistance = 36,
		.weight = 2,
		.maxCount = 20,
		.orderWeight = 800,
		.radiusMin = 300,
		.radiusMax = 460,
		.speedMin = 3,
		.speedMax = 8,
		.stretchMin = 0.28,
		.stretchMax = 0.5,
		.existMin = 280,
		.existMax = 480,
		.growMin = 40,
		.growMax = 70,
		.movesToPlayer = false,
		.layers = &.{
			.{
				.height = 56,
				.heightOffset = 0,
				.fadeDistance = 16,
				.scaleX = 220,
				.scaleY = 90,
				.scaleZ = 20,
				.valueOffset = 0.62,
				.valueScale = 0.8,
			},
			.{
				.height = 48,
				.heightOffset = 8,
				.fadeDistance = 12,
				.scaleX = 48,
				.scaleY = 48,
				.scaleZ = 16,
				.valueOffset = 0.02,
				.valueScale = 0.14,
			},
		},
	},
	.{
		.id = "nimbostratus",
		.weather = .thunderstorm,
		.storminess = 0.55,
		.stormStart = 8,
		.stormFadeDistance = 80,
		.weight = 1.5,
		.maxCount = 3,
		.orderWeight = 900,
		.radiusMin = 340,
		.radiusMax = 520,
		.speedMin = 2.5,
		.speedMax = 7,
		.stretchMin = 0.28,
		.stretchMax = 0.5,
		.existMin = 260,
		.existMax = 460,
		.growMin = 35,
		.growMax = 65,
		.movesToPlayer = false,
		.layers = &.{
			.{
				.height = 110,
				.heightOffset = 0,
				.fadeDistance = 26,
				.scaleX = 170,
				.scaleY = 170,
				.scaleZ = 36,
				.valueOffset = 0.7,
				.valueScale = 0.75,
			},
			.{
				.height = 90,
				.heightOffset = 48,
				.fadeDistance = 22,
				.scaleX = 150,
				.scaleY = 150,
				.scaleZ = 28,
				.valueOffset = 0.4,
				.valueScale = 0.55,
			},
			.{
				.height = 140,
				.heightOffset = 0,
				.fadeDistance = 20,
				.scaleX = 48,
				.scaleY = 48,
				.scaleZ = 22,
				.valueOffset = 0.06,
				.valueScale = 0.14,
			},
		},
	},
	.{
		.id = "cumulonimbus",
		.weather = .thunderstorm,
		.storminess = 0.6,
		.stormStart = 16,
		.stormFadeDistance = 512,
		.weight = 14,
		.maxCount = 3,
		.orderWeight = 1000,
		.radiusMin = 4000,
		.radiusMax = 8000,
		.speedMin = 2.5,
		.speedMax = 6,
		.stretchMin = 0.3,
		.stretchMax = 0.6,
		.existMin = 480,
		.existMax = 900,
		.growMin = 40,
		.growMax = 80,
		.movesToPlayer = true,
		.layers = &.{
			.{
				.height = 48,
				.heightOffset = 0,
				.fadeDistance = 16,
				.scaleX = 80,
				.scaleY = 80,
				.scaleZ = 48,
				.valueOffset = 1.0,
				.valueScale = 1,
			},
			.{
				.height = 1024,
				.heightOffset = 0,
				.fadeDistance = 96,
				.scaleX = 520,
				.scaleY = 520,
				.scaleZ = 640,
				.valueOffset = 0.32,
				.valueScale = 1,
			},
			.{
				.height = 1024,
				.heightOffset = 0,
				.fadeDistance = 80,
				.scaleX = 140,
				.scaleY = 140,
				.scaleZ = 160,
				.valueOffset = 0,
				.valueScale = 0.06,
			},
		},
	},
};

var pipeline: graphics.Pipeline = undefined;
var uniforms: struct {
	ambientLight: c_int,
	screenSize: c_int,
	skipDepthTests: c_int,
	@"fog.color": c_int,
	@"fog.density": c_int,
	@"fog.fogLower": c_int,
	@"fog.fogHigher": c_int,
} = undefined;
var meshPipeline: graphics.ComputePipeline = undefined;
var meshUniforms: struct {
	gridOrigin: c_int,
	playerPos: c_int,
	voxelSize: c_int,
	scroll: c_int,
	regionCount: c_int,
	maxSides: c_int,
	edgeFade: c_int,
	innerRadius: c_int,
	outerRadius: c_int,
	fadeDt: c_int,
	lodFadeDt: c_int,
	frameDt: c_int,
	lodHoldTime: c_int,
	occupancyOffset: c_int,
	gridX: c_int,
	gridY: c_int,
	gridZ: c_int,
} = undefined;
var cubeVao: graphics.VertexArray = undefined;
var cmdSsbo: graphics.SSBO = undefined;
var sidesSsbo: graphics.SSBO = undefined;
var layersSsbo: graphics.SSBO = undefined;
var groupsSsbo: graphics.SSBO = undefined;
var regionsSsbo: graphics.SSBO = undefined;
var occupancySsbo: graphics.SSBO = undefined;
var lodGridOrigin: [cloudLods.len]Vec3f = undefined;
var lodGridReady: [cloudLods.len]bool = [_]bool{false} ** cloudLods.len;

var config: Config = .{};
var lastReloadNs: i96 = 0;
var cloudTime: f64 = 0;
var spawnTimer: f32 = 0;
var rngSeed: u64 = 1;
var regions: [maxRegions]Region = undefined;
var regionCount: usize = 0;
var lastWorld: ?*main.game.World = null;
pub var lookingAtType: []const u8 = "none";

pub const DayKind = enum {
	sunny,
	cloudy,
	rain,
	storm_start,
	storm,
	storm_end,
};

const DayProfile = struct {
	minRegions: u32,
	maxRegions: u32,
	weights: [maxTypes]f32,
	maxCounts: [maxTypes]u32,
	allowRain: bool,
	allowThunder: bool,
	stormCap: u32,
};

const Climate = struct {
	active: DayKind = .cloudy,
	next: DayKind = .cloudy,
	mix: f32 = 0,
	stormTarget: u32 = 2,
};

var climate: Climate = .{};

fn profileFor(kind: DayKind) DayProfile {
	return switch (kind) {
		.sunny => .{
			.minRegions = 8,
			.maxRegions = 20,
			.weights = .{ 8, 50, 70, 8, 0, 0, 0 },
			.maxCounts = .{ 20, 20, 20, 8, 0, 0, 0 },
			.allowRain = false,
			.allowThunder = false,
			.stormCap = 0,
		},
		.cloudy => .{
			.minRegions = 20,
			.maxRegions = 80,
			.weights = .{ 10, 90, 120, 16, 0, 0, 0 },
			.maxCounts = .{ 20, 80, 80, 24, 0, 0, 0 },
			.allowRain = false,
			.allowThunder = false,
			.stormCap = 0,
		},
		.rain => .{
			.minRegions = 20,
			.maxRegions = 60,
			.weights = .{ 4, 12, 16, 100, 6, 0, 0 },
			.maxCounts = .{ 10, 24, 24, 60, 8, 0, 0 },
			.allowRain = true,
			.allowThunder = false,
			.stormCap = 0,
		},
		.storm_start => .{
			.minRegions = 20,
			.maxRegions = 20,
			.weights = .{ 0, 0, 0, 35, 0, 0, 90 },
			.maxCounts = .{ 0, 0, 0, 20, 0, 0, 3 },
			.allowRain = false,
			.allowThunder = true,
			.stormCap = 3,
		},
		.storm => .{
			.minRegions = 20,
			.maxRegions = 20,
			.weights = .{ 0, 0, 0, 35, 0, 0, 90 },
			.maxCounts = .{ 0, 0, 0, 20, 0, 0, 3 },
			.allowRain = true,
			.allowThunder = true,
			.stormCap = 3,
		},
		.storm_end => .{
			.minRegions = 20,
			.maxRegions = 20,
			.weights = .{ 0, 0, 0, 80, 0, 0, 0 },
			.maxCounts = .{ 0, 0, 0, 20, 0, 0, 0 },
			.allowRain = false,
			.allowThunder = false,
			.stormCap = 0,
		},
	};
}

fn rollKind(day: i64) DayKind {
	var seed: u64 = config.seed ^ (@as(u64, @bitCast(day)) *% 0x9E3779B97F4A7C15);
	const r = random.nextFloat(&seed);
	if (r < 0.40) return .sunny;
	if (r < 0.70) return .cloudy;
	if (r < 0.95) return .rain;
	return .storm_start;
}

fn kindForDay(day: i64) DayKind {
	if (day >= 2 and rollKind(day - 2) == .storm_start) return .storm_end;
	if (day >= 1 and rollKind(day - 1) == .storm_start) return .storm;
	return rollKind(day);
}

fn periodIndex(gameTime: i64) i64 {
	const dayTime = @mod(gameTime, gameDayTicks);
	const day = @divFloor(gameTime, gameDayTicks);
	return if (dayTime >= 8250) day + 1 else day;
}

fn nightTransition(gameTime: i64) f32 {
	const dayTime = @mod(gameTime, gameDayTicks);
	if (dayTime < 6000 or dayTime >= 8250) return 0;
	return @as(f32, @floatFromInt(dayTime - 6000))/2250.0;
}

fn updateClimate(gameTime: i64) void {
	const period = periodIndex(gameTime);
	climate.active = kindForDay(period);
	climate.next = kindForDay(period + 1);
	climate.mix = nightTransition(gameTime);
	if (climate.active == .storm_start) {
		var seed: u64 = config.seed ^ (@as(u64, @bitCast(period)) *% 0xBF58476D1CE4E5B9);
		climate.stormTarget = 1 + @as(u32, @intFromFloat(random.nextFloat(&seed)*2.999));
	} else if (climate.active == .storm or climate.active == .storm_end) {
		const startDay = if (climate.active == .storm) period - 1 else period - 2;
		var seed: u64 = config.seed ^ (@as(u64, @bitCast(startDay)) *% 0xBF58476D1CE4E5B9);
		climate.stormTarget = 1 + @as(u32, @intFromFloat(random.nextFloat(&seed)*2.999));
	} else {
		climate.stormTarget = 0;
	}
}

fn mixProfile() DayProfile {
	const a = profileFor(climate.active);
	const b = profileFor(climate.next);
	const t = climate.mix;
	var mixed = a;
	mixed.minRegions = @intFromFloat(mix(@floatFromInt(a.minRegions), @floatFromInt(b.minRegions), t));
	mixed.maxRegions = @intFromFloat(mix(@floatFromInt(a.maxRegions), @floatFromInt(b.maxRegions), t));
	mixed.stormCap = @intFromFloat(mix(@floatFromInt(a.stormCap), @floatFromInt(b.stormCap), t));
	inline for (0..maxTypes) |i| {
		mixed.weights[i] = mix(a.weights[i], b.weights[i], t);
		mixed.maxCounts[i] = @intFromFloat(mix(@floatFromInt(a.maxCounts[i]), @floatFromInt(b.maxCounts[i]), t) + 0.5);
	}
	mixed.allowRain = if (t < 0.5) a.allowRain else b.allowRain;
	mixed.allowThunder = if (t < 0.5) a.allowThunder else b.allowThunder;
	if (mixed.maxRegions > maxRegions) mixed.maxRegions = maxRegions;
	if (mixed.minRegions > mixed.maxRegions) mixed.minRegions = mixed.maxRegions;
	return mixed;
}

fn kindFactor(kind: DayKind) f32 {
	const a: f32 = if (climate.active == kind) 1 else 0;
	const b: f32 = if (climate.next == kind) 1 else 0;
	return mix(a, b, climate.mix);
}

pub fn rainDayFactor() f32 {
	return kindFactor(.rain);
}

pub fn stormWeatherFactor() f32 {
	return kindFactor(.storm) + kindFactor(.storm_start)*0.25 + kindFactor(.storm_end)*0.45;
}

pub fn climateLabel() []const u8 {
	if (climate.mix > 0.02) {
		return switch (climate.next) {
			.sunny => "transicion->soleado",
			.cloudy => "transicion->nubes",
			.rain => "transicion->lluvia",
			.storm_start => "transicion->aparicion_tormenta",
			.storm => "transicion->tormenta",
			.storm_end => "transicion->tormenta_fin",
		};
	}
	return switch (climate.active) {
		.sunny => "soleado",
		.cloudy => "nubes",
		.rain => "lluvia",
		.storm_start => "aparicion_tormenta",
		.storm => "tormenta",
		.storm_end => "tormenta_fin",
	};
}

fn regionOpacity(region: Region) f32 {
	const fadeIn = std.math.clamp(region.age/region.fadeIn, 0, 1);
	const fadeOut = std.math.clamp((region.existTime - region.age)/region.fadeOut, 0, 1);
	return fadeIn*fadeOut;
}

pub fn init() void {
	pipeline = graphics.Pipeline.init(
		"assets/cubyz/shaders/clouds/clouds.vert",
		"assets/cubyz/shaders/clouds/clouds.frag",
		"",
		&uniforms,
		graphics.VertexArray.EmptyVertex,
		.{
			.rasterState = .{.cullMode = .none},
			.depthStencilState = .{.depthTest = true, .depthWrite = true},
			.blendState = .{.attachments = &.{.noBlending}, .formats = &.{.swapChain}},
		},
	);
	meshPipeline = graphics.ComputePipeline.init("assets/cubyz/shaders/clouds/mesh.comp", "", &meshUniforms);
	cmdSsbo = graphics.SSBO.initDynamicSize(IndirectCommand, 1);
	sidesSsbo = graphics.SSBO.initDynamicSize(extern struct {
		side: i32,
		x: f32,
		y: f32,
		z: f32,
		brightness: f32,
		radius: f32,
		opacity: f32,
	}, maxSides);
	layersSsbo = graphics.SSBO.initDynamicSize(NoiseLayer, maxLayers);
	groupsSsbo = graphics.SSBO.initDynamicSize(LayerGroup, maxTypes);
	regionsSsbo = graphics.SSBO.initDynamicSize(GpuRegion, maxRegions);
	occupancySsbo = graphics.SSBO.initDynamicSize(GpuOccupancy, occupancyTotal);
	cubeVao = .init(DummyVertex, &.{.{}}, null);
	loadConfig();
	rngSeed = config.seed;
}

pub fn deinit() void {
	pipeline.deinit();
	meshPipeline.deinit();
	cmdSsbo.deinit();
	sidesSsbo.deinit();
	layersSsbo.deinit();
	groupsSsbo.deinit();
	regionsSsbo.deinit();
	occupancySsbo.deinit();
	cubeVao.deinit();
}

pub fn weatherAt(x: f64, y: f64, z: f64) Weather {
	const sample = sampleRegion(@floatCast(x), @floatCast(y));
	if (sample.typeIndex < 0 or sample.inner < rainThreshold) return .none;
	const def = typeDefs[@intCast(sample.typeIndex)];
	if (z > @as(f64, @floatCast(config.height + def.stormStart + 48))) return .none;
	return def.weather;
}

pub fn rainLevelAt(x: f64, y: f64, z: f64) f32 {
	return rainInfluenceAt(x, y, z);
}

pub fn rainInfluenceAt(x: f64, y: f64, z: f64) f32 {
	var influence: f32 = 0;
	const px: f32 = @floatCast(x);
	const py: f32 = @floatCast(y);
	const pz: f32 = @floatCast(z);
	for (regions[0..regionCount]) |region| {
		const def = typeDefs[region.typeIndex];
		if (def.weather == .none) continue;
		const dx = px - region.posX;
		const dy = py - region.posY;
		const cosR = @cos(region.rotation);
		const sinR = @sin(region.rotation);
		var rx = cosR*dx + sinR*dy;
		const ry = -sinR*dx + cosR*dy;
		rx /= @max(region.stretch, 0.01);
		const dist = @sqrt(rx*rx + ry*ry);
		const inner = region.radius*0.2;
		const outer = region.radius + rainFogMargin;
		const t = std.math.clamp((outer - dist)/@max(outer - inner, 1), 0, 1);
		const smooth = t*t*(3 - 2*t);
		influence = @max(influence, smooth);
	}
	if (pz > 512) {
		const above = std.math.clamp(1 - (pz - 512)/40, 0, 1);
		influence *= above;
	}
	return influence;
}

pub fn stormDarknessAt(x: f64, y: f64, z: f64) f32 {
	var darkness: f32 = 0;
	const px: f32 = @floatCast(x);
	const py: f32 = @floatCast(y);
	const pz: f32 = @floatCast(z);
	if (pz > 512) {
		const above = std.math.clamp(1 - (pz - 512)/40, 0, 1);
		if (above <= 0) return 0;
	}
	for (regions[0..regionCount]) |region| {
		const def = typeDefs[region.typeIndex];
		if (!std.mem.eql(u8, def.id, "cumulonimbus")) continue;
		const dx = px - region.posX;
		const dy = py - region.posY;
		const cosR = @cos(region.rotation);
		const sinR = @sin(region.rotation);
		var rx = cosR*dx + sinR*dy;
		const ry = -sinR*dx + cosR*dy;
		rx /= @max(region.stretch, 0.01);
		const dist = @sqrt(rx*rx + ry*ry);
		if (dist > region.radius) continue;
		const t = std.math.clamp((region.radius - dist)/@max(region.radius*0.35, 1), 0, 1);
		darkness = @max(darkness, t*t*(3 - 2*t));
	}
	if (pz > 512) {
		darkness *= std.math.clamp(1 - (pz - 512)/40, 0, 1);
	}
	return darkness;
}

pub fn stratoCoverAt(x: f64, y: f64, z: f64) f32 {
	var cover: f32 = 0;
	const px: f32 = @floatCast(x);
	const py: f32 = @floatCast(y);
	const pz: f32 = @floatCast(z);
	for (regions[0..regionCount]) |region| {
		const def = typeDefs[region.typeIndex];
		if (!std.mem.eql(u8, def.id, "stratocumulus")) continue;
		const dx = px - region.posX;
		const dy = py - region.posY;
		const cosR = @cos(region.rotation);
		const sinR = @sin(region.rotation);
		var rx = cosR*dx + sinR*dy;
		const ry = -sinR*dx + cosR*dy;
		rx /= @max(region.stretch, 0.01);
		const dist = @sqrt(rx*rx + ry*ry);
		if (dist > region.radius) continue;
		const t = std.math.clamp((region.radius - dist)/@max(region.radius*0.4, 1), 0, 1);
		cover = @max(cover, t*t*(3 - 2*t)*regionOpacity(region));
	}
	if (pz > 512) {
		cover *= std.math.clamp(1 - (pz - 512)/40, 0, 1);
	}
	return cover;
}

pub fn render(frustum: *const main.renderer.Frustum, playerPos: Vec3d, ambientLight: Vec3f, deltaTime: f64) void {
	_ = frustum;
	maybeReloadConfig();
	const world = main.game.world orelse {
		lastWorld = null;
		regionCount = 0;
		lookingAtType = "none";
		lodGridReady = [_]bool{false} ** cloudLods.len;
		return;
	};
	if (lastWorld != world) {
		lastWorld = world;
		regionCount = 0;
		cloudTime = 0;
		spawnTimer = 0;
		lodGridReady = [_]bool{false} ** cloudLods.len;
		rngSeed = config.seed ^ @as(u64, @bitCast(world.gameTime.load(.monotonic)));
		updateClimate(world.gameTime.load(.monotonic));
		const live = mixProfile();
		var i: usize = 0;
		while (i < 600 and regionCount < live.minRegions) : (i += 1) {
			trySpawnRegion(playerPos, false, null);
		}
		if (live.allowThunder and climate.stormTarget > 0) {
			var storms: u32 = 0;
			while (storms < climate.stormTarget and regionCount < live.maxRegions) : (storms += 1) {
				trySpawnRegion(playerPos, false, 6);
			}
		}
	}
	if (!world.paused) {
		updateClimate(world.gameTime.load(.monotonic));
		cloudTime += deltaTime;
		tickRegions(playerPos, @floatCast(deltaTime));
	}

	updateLookingAt(playerPos);

	const playerBlock = main.renderer.mesh_storage.getBlockFromAnyLodFromRenderThread(@floor(playerPos[0]), @floor(playerPos[1]), @floor(playerPos[2]));
	const underFluid = playerBlock.hasTag(.fluid);
	if (!underFluid and regionCount != 0) {
		renderCloudMesh(playerPos, ambientLight, world, @floatCast(deltaTime));
	}
	if (main.gui.isWindowOpen("debug") and regionCount != 0) {
		renderDebugBoxes(playerPos);
	}
}

fn renderCloudMesh(playerPos: Vec3d, ambientLight: Vec3f, world: *main.game.World, deltaTime: f32) void {
	uploadCloudData(playerPos);

	const playerF: Vec3f = .{@floatCast(playerPos[0]), @floatCast(playerPos[1]), @floatCast(playerPos[2])};
	const scroll: Vec3f = .{0, 0, 0};
	const fadeStep = @min(deltaTime, 0.25)/blockFadeTime;
	const lodFadeStep = @min(deltaTime, 0.25)/lodFadeTime;

	const command = IndirectCommand{};
	cmdSsbo.bufferSubData(IndirectCommand, &.{command}, 1);

	meshPipeline.bind();
	c.glUniform3f(meshUniforms.playerPos, playerF[0], playerF[1], playerF[2]);
	c.glUniform3f(meshUniforms.scroll, scroll[0], scroll[1], scroll[2]);
	c.glUniform1i(meshUniforms.regionCount, @intCast(regionCount));
	c.glUniform1ui(meshUniforms.maxSides, maxSides);
	c.glUniform1f(meshUniforms.edgeFade, edgeFade);
	c.glUniform1f(meshUniforms.fadeDt, fadeStep);
	c.glUniform1f(meshUniforms.lodFadeDt, lodFadeStep);
	c.glUniform1f(meshUniforms.frameDt, @min(deltaTime, 0.25));
	c.glUniform1f(meshUniforms.lodHoldTime, lodFadeDelay);
	for (cloudLods, 0..) |lod, lodIndex| {
		const gridOrigin = stickyGridOrigin(playerPos, lod, lodIndex);
		c.glUniform3f(meshUniforms.gridOrigin, gridOrigin[0], gridOrigin[1], gridOrigin[2]);
		c.glUniform1f(meshUniforms.voxelSize, lod.voxelSize);
		c.glUniform1f(meshUniforms.innerRadius, lod.innerRadius);
		c.glUniform1f(meshUniforms.outerRadius, lod.outerRadius);
		c.glUniform1ui(meshUniforms.occupancyOffset, occupancyOffsets[lodIndex]);
		c.glUniform1ui(meshUniforms.gridX, lod.gridX);
		c.glUniform1ui(meshUniforms.gridY, lod.gridY);
		c.glUniform1ui(meshUniforms.gridZ, lod.gridZ);
		c.glDispatchCompute(lod.gridX/localX, lod.gridZ/localY, lod.gridY/localZ);
	}
	c.glMemoryBarrier(c.GL_SHADER_STORAGE_BARRIER_BIT | c.GL_COMMAND_BARRIER_BIT);

	var viewport: [4]c_int = undefined;
	c.glGetIntegerv(c.GL_VIEWPORT, &viewport);
	main.renderer.bindWorldDepthTexture(c.GL_TEXTURE4);
	pipeline.bind(null);
	c.glUniform3f(uniforms.ambientLight, ambientLight[0], ambientLight[1], ambientLight[2]);
	c.glUniform2f(uniforms.screenSize, @floatFromInt(viewport[2]), @floatFromInt(viewport[3]));
	c.glUniform1i(uniforms.skipDepthTests, if (config.debug != 0) 1 else 0);
	const fog = world.dayTime.fog;
	c.glUniform3fv(uniforms.@"fog.color", 1, @ptrCast(&fog.fogColor));
	c.glUniform1f(uniforms.@"fog.density", fog.density);
	c.glUniform1f(uniforms.@"fog.fogLower", fog.fogLower);
	c.glUniform1f(uniforms.@"fog.fogHigher", fog.fogHigher);
	cubeVao.bind();
	c.glBindBuffer(c.GL_DRAW_INDIRECT_BUFFER, cmdSsbo.bufferID);
	c.glDrawArraysIndirect(c.GL_TRIANGLES, null);
}

const RegionBounds = struct {
	min: Vec3f,
	max: Vec3f,
};

fn regionBounds(region: Region) RegionBounds {
	const def = typeDefs[region.typeIndex];
	const axisX = region.radius*@max(region.stretch, 0.01);
	const axisY = region.radius;
	const cosR = @cos(region.rotation);
	const sinR = @sin(region.rotation);
	const extX = @sqrt(axisX*axisX*cosR*cosR + axisY*axisY*sinR*sinR);
	const extY = @sqrt(axisX*axisX*sinR*sinR + axisY*axisY*cosR*cosR);
	var zMin: f32 = std.math.floatMax(f32);
	var zMax: f32 = -std.math.floatMax(f32);
	for (def.layers) |layer| {
		zMin = @min(zMin, config.height + layer.heightOffset);
		zMax = @max(zMax, config.height + layer.heightOffset + layer.height);
	}
	return .{
		.min = .{region.posX - extX, region.posY - extY, zMin},
		.max = .{region.posX + extX, region.posY + extY, zMax},
	};
}

fn rayAabb(origin: Vec3f, dir: Vec3f, min: Vec3f, max: Vec3f) ?f32 {
	const eps: f32 = 1e-8;
	var tMin: f32 = 0;
	var tMax: f32 = cloudHorizon();
	inline for (.{0, 1, 2}) |axis| {
		if (@abs(dir[axis]) < eps) {
			if (origin[axis] < min[axis] or origin[axis] > max[axis]) return null;
		} else {
			const inv = 1.0/dir[axis];
			var t0 = (min[axis] - origin[axis])*inv;
			var t1 = (max[axis] - origin[axis])*inv;
			if (t0 > t1) {
				const tmp = t0;
				t0 = t1;
				t1 = tmp;
			}
			tMin = @max(tMin, t0);
			tMax = @min(tMax, t1);
			if (tMin > tMax) return null;
		}
	}
	return tMin;
}

fn updateLookingAt(playerPos: Vec3d) void {
	lookingAtType = "none";
	if (regionCount == 0) return;
	const origin: Vec3f = .{@floatCast(playerPos[0]), @floatCast(playerPos[1]), @floatCast(playerPos[2])};
	const dir = main.game.camera.direction;
	var bestT: f32 = std.math.floatMax(f32);
	for (regions[0..regionCount]) |region| {
		const bounds = regionBounds(region);
		const hit = rayAabb(origin, dir, bounds.min, bounds.max) orelse continue;
		if (hit < bestT) {
			bestT = hit;
			lookingAtType = typeDefs[region.typeIndex].id;
		}
	}
}

fn renderDebugBoxes(playerPos: Vec3d) void {
	const playerF: Vec3f = .{@floatCast(playerPos[0]), @floatCast(playerPos[1]), @floatCast(playerPos[2])};
	for (regions[0..regionCount]) |region| {
		const bounds = regionBounds(region);
		const size = bounds.max - bounds.min;
		const center = (bounds.min + bounds.max)*@as(Vec3f, @splat(0.5));
		const delta = center - playerF;
		const dist = @sqrt(@reduce(.Add, delta*delta));
		const lineSize = @max(0.2, dist*0.0004 + @reduce(.Max, size)*0.0006);
		const rel: Vec3d = .{
			@floatCast(bounds.min[0] - playerF[0]),
			@floatCast(bounds.min[1] - playerF[1]),
			@floatCast(bounds.min[2] - playerF[2]),
		};
		main.renderer.MeshSelection.drawCubeColored(rel, .{0, 0, 0}, size, lineSize, .{0.15, 0.95, 1.0, 0.95}, false);
	}
}

fn stickyGridOrigin(playerPos: Vec3d, lod: CloudLod, lodIndex: usize) Vec3f {
	const desired = voxelGridOrigin(playerPos, lod);
	if (!lodGridReady[lodIndex]) {
		lodGridOrigin[lodIndex] = desired;
		lodGridReady[lodIndex] = true;
		return desired;
	}
	const snap = lod.voxelSize;
	const margin = snap*0.25;
	var last = lodGridOrigin[lodIndex];
	const extentX = @as(f32, @floatFromInt(lod.gridX))*lod.voxelSize;
	const extentY = @as(f32, @floatFromInt(lod.gridY))*lod.voxelSize;
	const rawX = @as(f32, @floatCast(playerPos[0])) - extentX*0.5;
	const rawY = @as(f32, @floatCast(playerPos[1])) - extentY*0.5;
	if (rawX >= last[0] + snap + margin) last[0] = desired[0];
	if (rawX < last[0] - margin) last[0] = desired[0];
	if (rawY >= last[1] + snap + margin) last[1] = desired[1];
	if (rawY < last[1] - margin) last[1] = desired[1];
	last[2] = desired[2];
	lodGridOrigin[lodIndex] = last;
	return last;
}

fn voxelGridOrigin(playerPos: Vec3d, lod: CloudLod) Vec3f {
	const extentX = @as(f32, @floatFromInt(lod.gridX))*lod.voxelSize;
	const extentY = @as(f32, @floatFromInt(lod.gridY))*lod.voxelSize;
	const snap = lod.voxelSize;
	const originX = @floor((@as(f32, @floatCast(playerPos[0])) - extentX*0.5)/snap)*snap;
	const originY = @floor((@as(f32, @floatCast(playerPos[1])) - extentY*0.5)/snap)*snap;
	const originZ = config.height - 16;
	return .{originX, originY, originZ};
}

fn cloudHorizon() f32 {
	const lod = cloudLods[cloudLods.len - 1];
	return @as(f32, @floatFromInt(lod.gridX))*lod.voxelSize*0.5;
}

fn uploadCloudData(playerPos: Vec3d) void {
	_ = playerPos;
	var packedLayers: [maxLayers]NoiseLayer = undefined;
	var packedGroups: [maxTypes]LayerGroup = undefined;
	var layerCount: i32 = 0;
	for (typeDefs, 0..) |def, typeIndex| {
		const start = layerCount;
		for (def.layers) |layer| {
			packedLayers[@intCast(layerCount)] = .{
				.height = layer.height,
				.heightOffset = config.height + layer.heightOffset,
				.fadeDistance = layer.fadeDistance,
				.scaleX = layer.scaleX,
				.scaleY = layer.scaleY,
				.scaleZ = layer.scaleZ,
				.valueOffset = layer.valueOffset,
				.valueScale = layer.valueScale,
			};
			layerCount += 1;
		}
		packedGroups[typeIndex] = .{
			.startIndex = start,
			.endIndex = layerCount,
			.storminess = def.storminess,
			.stormStart = config.height + def.stormStart,
			.stormFadeDistance = def.stormFadeDistance,
		};
	}
	layersSsbo.bufferSubData(NoiseLayer, packedLayers[0..@intCast(layerCount)], @intCast(layerCount));
	groupsSsbo.bufferSubData(LayerGroup, packedGroups[0..typeDefs.len], typeDefs.len);

	var gpuRegions: [maxRegions]GpuRegion = undefined;
	sortRegionsByOrder();
	for (0..regionCount) |i| {
		gpuRegions[i] = .{
			.posX = regions[i].posX,
			.posY = regions[i].posY,
			.radius = regions[i].radius,
			.stretch = regions[i].stretch,
			.rotation = regions[i].rotation,
			.typeIndex = @floatFromInt(regions[i].typeIndex),
			.opacity = regionOpacity(regions[i]),
		};
	}
	if (regionCount != 0) {
		regionsSsbo.bufferSubData(GpuRegion, gpuRegions[0..regionCount], regionCount);
	}

	cmdSsbo.bind(17);
	sidesSsbo.bind(18);
	layersSsbo.bind(19);
	groupsSsbo.bind(20);
	regionsSsbo.bind(21);
	occupancySsbo.bind(22);
}

fn sortRegionsByOrder() void {
	var i: usize = 1;
	while (i < regionCount) : (i += 1) {
		var j = i;
		while (j > 0 and regions[j - 1].orderWeight > regions[j].orderWeight) {
			const tmp = regions[j - 1];
			regions[j - 1] = regions[j];
			regions[j] = tmp;
			j -= 1;
		}
	}
}

fn tickRegions(playerPos: Vec3d, dt: f32) void {
	const windLen = @sqrt(config.windX*config.windX + config.windY*config.windY);
	const windX = if (windLen > 0) config.windX/windLen else 1;
	const windY = if (windLen > 0) config.windY/windLen else 0;
	const playerX: f32 = @floatCast(playerPos[0]);
	const playerY: f32 = @floatCast(playerPos[1]);
	var i: usize = 0;
	while (i < regionCount) {
		var region = &regions[i];
		region.age += dt;
		region.radius = region.targetRadius;
		region.posX += (region.velX + windX*config.speed)*dt;
		region.posY += (region.velY + windY*config.speed)*dt;
		const dx = region.posX - playerX;
		const dy = region.posY - playerY;
		const maxDist = cloudHorizon()*0.95;
		const tooFar = dx*dx + dy*dy > maxDist*maxDist;
		if (tooFar) {
			region.existTime = @min(region.existTime, region.age + region.fadeOut);
		}
		if (region.age > region.existTime) {
			regions[i] = regions[regionCount - 1];
			regionCount -= 1;
			continue;
		}
		i += 1;
	}
	const live = mixProfile();
	trimToQuota(live);
	fadeStormClouds(live);
	spawnTimer -= dt;
	const needMore = regionCount < live.minRegions;
	if (spawnTimer <= 0 or needMore) {
		if (!needMore) spawnTimer = 0.6 + random.nextFloat(&rngSeed)*1.4;
		var spawned: u32 = 0;
		while (spawned < 12 and regionCount < live.maxRegions) : (spawned += 1) {
			const before = regionCount;
			trySpawnRegion(playerPos, false, null);
			if (regionCount == before) break;
		}
		if (live.allowThunder and countType(6) < climate.stormTarget) {
			trySpawnRegion(playerPos, false, 6);
		}
		if (regionCount < live.minRegions) spawnTimer = 0;
	}
}

fn trySpawnRegion(playerPos: Vec3d, fairOnly: bool, forcedType: ?usize) void {
	const live = mixProfile();
	if (regionCount >= live.maxRegions or regionCount >= maxRegions) return;
	var attempt: usize = 0;
	while (attempt < spawnAttempts) : (attempt += 1) {
		const typeIndex = forcedType orelse pickType(fairOnly, live);
		const def = typeDefs[typeIndex];
		if (def.weather == .rain and !live.allowRain) continue;
		if (def.weather == .thunderstorm and (!live.allowThunder or countStorms() >= live.stormCap)) continue;
		if (countType(typeIndex) >= live.maxCounts[typeIndex]) continue;
		const angle = random.nextFloat(&rngSeed)*std.math.tau;
		const dist = @sqrt(random.nextFloat(&rngSeed))*cloudHorizon()*0.9;
		const posX = @as(f32, @floatCast(playerPos[0])) + @cos(angle)*dist;
		const posY = @as(f32, @floatCast(playerPos[1])) + @sin(angle)*dist;
		const separation = if (def.weather == .thunderstorm) 900 else minRegionSeparation;
		if (tooClose(posX, posY, separation, def.weather == .thunderstorm)) continue;

		const targetRadius = mix(def.radiusMin, def.radiusMax, random.nextFloat(&rngSeed));
		var dirX = config.windX;
		var dirY = config.windY;
		if (def.movesToPlayer) {
			dirX = @as(f32, @floatCast(playerPos[0])) - posX;
			dirY = @as(f32, @floatCast(playerPos[1])) - posY;
		}
		const dirLen = @sqrt(dirX*dirX + dirY*dirY);
		if (dirLen > 0.001) {
			dirX /= dirLen;
			dirY /= dirLen;
		} else {
			dirX = 1;
			dirY = 0;
		}
		const maxSpeed = mix(def.speedMin, def.speedMax, random.nextFloat(&rngSeed));
		const growTime = mix(def.growMin, def.growMax, random.nextFloat(&rngSeed));
		const ownSpeed: f32 = if (def.movesToPlayer) maxSpeed*0.02 else 0;
		const stormyCb = typeIndex == 6 and (climate.active == .storm_start or climate.next == .storm_start or climate.active == .storm_end or climate.next == .storm_end);
		regions[regionCount] = .{
			.typeIndex = @intCast(typeIndex),
			.posX = posX,
			.posY = posY,
			.radius = targetRadius,
			.targetRadius = targetRadius,
			.stretch = mix(def.stretchMin, def.stretchMax, random.nextFloat(&rngSeed)),
			.rotation = std.math.atan2(dirY, dirX),
			.velX = dirX*ownSpeed,
			.velY = dirY*ownSpeed,
			.maxSpeed = maxSpeed,
			.age = 0,
			.growTime = growTime,
			.existTime = mix(def.existMin, def.existMax, random.nextFloat(&rngSeed)),
			.orderWeight = def.orderWeight,
			.fadeIn = if (stormyCb) stormCloudFadeTime else blockFadeTime,
			.fadeOut = if (typeIndex == 6) stormCloudFadeTime else blockFadeTime,
		};
		regionCount += 1;
		return;
	}
}

fn tooClose(x: f32, y: f32, minSep: f32, stormsOnly: bool) bool {
	for (regions[0..regionCount]) |region| {
		if (stormsOnly and typeDefs[region.typeIndex].weather != .thunderstorm) continue;
		const dx = x - region.posX;
		const dy = y - region.posY;
		if (dx*dx + dy*dy < minSep*minSep) return true;
	}
	return false;
}

fn countStorms() usize {
	var count: usize = 0;
	for (regions[0..regionCount]) |region| {
		if (typeDefs[region.typeIndex].weather == .thunderstorm) count += 1;
	}
	return count;
}

fn countType(typeIndex: usize) u32 {
	var count: u32 = 0;
	for (regions[0..regionCount]) |region| {
		if (region.typeIndex == typeIndex) count += 1;
	}
	return count;
}

fn pickType(fairOnly: bool, live: DayProfile) usize {
	var total: f32 = 0;
	for (typeDefs, 0..) |def, i| {
		if (fairOnly and def.weather != .none) continue;
		if (def.weather == .rain and !live.allowRain) continue;
		if (def.weather == .thunderstorm and !live.allowThunder) continue;
		if (countType(i) >= live.maxCounts[i]) continue;
		if (live.weights[i] <= 0) continue;
		total += live.weights[i];
	}
	if (total <= 0) return 0;
	var remaining = random.nextFloat(&rngSeed)*total;
	for (typeDefs, 0..) |def, i| {
		if (fairOnly and def.weather != .none) continue;
		if (def.weather == .rain and !live.allowRain) continue;
		if (def.weather == .thunderstorm and !live.allowThunder) continue;
		if (countType(i) >= live.maxCounts[i]) continue;
		if (live.weights[i] <= 0) continue;
		remaining -= live.weights[i];
		if (remaining <= 0) return i;
	}
	return 0;
}

fn trimToQuota(live: DayProfile) void {
	if (regionCount <= live.maxRegions) return;
	var extra: usize = regionCount - live.maxRegions;
	while (extra > 0) : (extra -= 1) {
		var worst: ?usize = null;
		var worstWeight: f32 = std.math.floatMax(f32);
		for (regions[0..regionCount], 0..) |region, i| {
			const remaining = region.existTime - region.age;
			if (remaining <= region.fadeOut + 0.1) continue;
			const weight = live.weights[region.typeIndex];
			if (weight <= worstWeight) {
				worstWeight = weight;
				worst = i;
			}
		}
		if (worst) |index| {
			regions[index].existTime = regions[index].age + regions[index].fadeOut;
		} else break;
	}
}

fn fadeStormClouds(live: DayProfile) void {
	_ = live;
	const ending = climate.active == .storm_end or climate.next == .storm_end;
	if (!ending) return;
	for (regions[0..regionCount]) |*region| {
		if (region.typeIndex != 6) continue;
		region.fadeOut = stormCloudFadeTime;
		if (region.existTime - region.age > stormCloudFadeTime) {
			region.existTime = region.age + stormCloudFadeTime;
		}
	}
}

const RegionSample = struct {
	typeIndex: i32,
	inner: f32,
};

fn sampleRegion(x: f32, y: f32) RegionSample {
	var result = RegionSample{.typeIndex = -1, .inner = 0};
	for (regions[0..regionCount]) |region| {
		const dx = x - region.posX;
		const dy = y - region.posY;
		const cosR = @cos(region.rotation);
		const sinR = @sin(region.rotation);
		var rx = cosR*dx + sinR*dy;
		const ry = -sinR*dx + cosR*dy;
		rx /= @max(region.stretch, 0.01);
		const dist = @sqrt(rx*rx + ry*ry);
		if (dist > region.radius + edgeFade) continue;
		const inner = std.math.clamp((region.radius - dist)/edgeFade, 0, 1);
		if (inner > result.inner) {
			result.typeIndex = @intCast(region.typeIndex);
			result.inner = inner;
		}
	}
	return result;
}

fn mix(a: f32, b: f32, t: f32) f32 {
	return a + (b - a)*t;
}

fn maybeReloadConfig() void {
	const now = main.timestamp().toNanoseconds();
	if (now - lastReloadNs < reloadInterval.toNanoseconds()) return;
	lastReloadNs = now;
	loadConfig();
}

fn loadConfig() void {
	const file = main.files.cwd().read(main.stackAllocator, configPath) catch |err| {
		if (err != error.FileNotFound) {
			std.log.err("Could not read {s}: {s}", .{configPath, @errorName(err)});
		}
		return;
	};
	defer main.stackAllocator.free(file);

	var parsed: Config = .{};
	var lines = std.mem.splitScalar(u8, file, '\n');
	while (lines.next()) |rawLine| {
		const line = std.mem.trim(u8, std.mem.trim(u8, rawLine, "\r"), " \t");
		if (line.len == 0 or line[0] == '#') continue;
		const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
		const key = std.mem.trim(u8, line[0..eq], " \t");
		const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
		if (std.mem.eql(u8, key, "seed")) {
			parsed.seed = std.fmt.parseInt(u64, value, 10) catch parsed.seed;
			continue;
		}
		const number = std.fmt.parseFloat(f32, value) catch continue;
		if (std.mem.eql(u8, key, "height")) {
			parsed.height = number;
		} else if (std.mem.eql(u8, key, "speed")) {
			parsed.speed = @max(number, 0);
		} else if (std.mem.eql(u8, key, "wind_x")) {
			parsed.windX = number;
		} else if (std.mem.eql(u8, key, "wind_y")) {
			parsed.windY = number;
		} else if (std.mem.eql(u8, key, "debug")) {
			parsed.debug = number;
		}
	}
	config = parsed;
}
