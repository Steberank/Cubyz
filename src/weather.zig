//! Weather state shared between the client and the server.
//!
//! The world's weather is a small set of elliptical *cloud regions*, each of
//! which claims a patch of the world for one cloud type and therefore decides
//! what the sky looks like there and whether it rains. The server owns them and
//! broadcasts them; the client only simulates them between snapshots so that
//! their motion stays smooth.
//!
//! Everything here works in *cloud space*: one unit is `cloudScale` blocks and Z
//! points up. Radii and speeds coming from the cloud type assets are in blocks
//! and blocks per second, and get converted on the way in.

const std = @import("std");

const main = @import("main");
const vec = main.vec;
const Vec2d = vec.Vec2d;
const Vec2f = vec.Vec2f;
const ZonElement = main.ZonElement;

pub const CloudType = @import("weather/CloudType.zig");

/// How many blocks one cloud space unit spans.
pub const cloudScale = 8;
/// Horizontal size of a cloud chunk, in voxels.
pub const chunkSize = 32;
/// How many chunks tall the cloud volume is.
pub const verticalChunkSpan = 8;

/// How many formations may exist at once. Also the size of the network snapshot.
pub const maxFormations = 8;

/// Reciprocal of the width of the soft rim around a region, in cloud units. The
/// rim is where a formation fades into its surroundings, so it is also where the
/// rain tapers off.
pub const regionEdgeFadeFactor = 0.005;

/// One in game day in seconds, so that durations can be read as day counts.
pub const dayLength = 1200.0;

// MARK: Region

pub const Region = struct {
	typeIndex: u32,
	/// Absolute cloud space position, in f64 because worlds are huge.
	pos: Vec2d,
	direction: Vec2f,
	/// Cloud space units per second.
	velocity: Vec2f,
	maxSpeed: f32,
	acceleration: f32,
	initialRadius: f32,
	radius: f32,
	rotation: f32,
	stretch: f32,
	orderWeight: f32,
	age: f32,
	/// How long the formation takes to reach its full radius, and how long it
	/// exists in total. It shrinks back to nothing over the remainder.
	growTime: f32,
	lifetime: f32,

	/// `scale(stretch, 1) * rotate(rotation)`, in the column major order a GLSL
	/// `mat2` expects.
	pub fn transform(self: Region) [4]f32 {
		const sin = @sin(self.rotation);
		const cos = @cos(self.rotation);
		return .{self.stretch*cos, sin, -self.stretch*sin, cos};
	}

	pub fn advance(self: *Region, deltaTime: f32) void {
		const scale = if (self.age < self.growTime)
			self.age/@max(self.growTime, 0.001)
		else
			1 - (self.age - self.growTime)/@max(self.lifetime - self.growTime, 0.001);
		self.radius = self.initialRadius*std.math.clamp(scale, 0, 1);

		self.age += deltaTime;

		const target = @abs(self.direction*@as(Vec2f, @splat(self.maxSpeed)));
		const accelerated = self.velocity + self.direction*@as(Vec2f, @splat(self.acceleration*deltaTime));
		self.velocity = @min(@max(accelerated, -target), target);
		self.pos += @as(Vec2d, @floatCast(self.velocity*@as(Vec2f, @splat(deltaTime))));
	}

	pub fn isDead(self: Region) bool {
		return self.age >= self.lifetime;
	}

	pub fn toZon(self: Region, allocator: main.heap.NeverFailingAllocator) ZonElement {
		const zon = ZonElement.initObject(allocator);
		// Stored by id so that adding or reordering cloud types cannot silently
		// turn a stored formation into a different kind of weather.
		zon.putOwnedString("type", CloudType.get(self.typeIndex).id);
		zon.put("posX", self.pos[0]);
		zon.put("posY", self.pos[1]);
		zon.put("dirX", self.direction[0]);
		zon.put("dirY", self.direction[1]);
		zon.put("velX", self.velocity[0]);
		zon.put("velY", self.velocity[1]);
		zon.put("maxSpeed", self.maxSpeed);
		zon.put("acceleration", self.acceleration);
		zon.put("initialRadius", self.initialRadius);
		zon.put("rotation", self.rotation);
		zon.put("stretch", self.stretch);
		zon.put("age", self.age);
		zon.put("growTime", self.growTime);
		zon.put("lifetime", self.lifetime);
		return zon;
	}

	pub fn fromZon(zon: ZonElement) ?Region {
		const id = zon.get([]const u8, "type") orelse return null;
		const typeIndex = CloudType.indexOf(id) orelse return null;
		var region: Region = .{
			.typeIndex = typeIndex,
			.pos = .{zon.get(f64, "posX") orelse 0, zon.get(f64, "posY") orelse 0},
			.direction = .{zon.get(f32, "dirX") orelse 1, zon.get(f32, "dirY") orelse 0},
			.velocity = .{zon.get(f32, "velX") orelse 0, zon.get(f32, "velY") orelse 0},
			.maxSpeed = zon.get(f32, "maxSpeed") orelse 0,
			.acceleration = zon.get(f32, "acceleration") orelse 0,
			.initialRadius = zon.get(f32, "initialRadius") orelse 0,
			.radius = 0,
			.rotation = zon.get(f32, "rotation") orelse 0,
			.stretch = zon.get(f32, "stretch") orelse 1,
			.orderWeight = CloudType.get(typeIndex).spawning.orderWeight,
			.age = zon.get(f32, "age") orelse 0,
			.growTime = zon.get(f32, "growTime") orelse 0,
			.lifetime = zon.get(f32, "lifetime") orelse 1,
		};
		// Recompute the radius from the age instead of storing it.
		region.advance(0);
		return region;
	}

	pub fn write(self: Region, writer: *main.utils.BinaryWriter) void {
		writer.writeSliceWithSize(CloudType.get(self.typeIndex).id);
		writer.writeFloat(f64, self.pos[0]);
		writer.writeFloat(f64, self.pos[1]);
		writer.writeFloat(f32, self.direction[0]);
		writer.writeFloat(f32, self.direction[1]);
		writer.writeFloat(f32, self.velocity[0]);
		writer.writeFloat(f32, self.velocity[1]);
		writer.writeFloat(f32, self.maxSpeed);
		writer.writeFloat(f32, self.acceleration);
		writer.writeFloat(f32, self.initialRadius);
		writer.writeFloat(f32, self.radius);
		writer.writeFloat(f32, self.rotation);
		writer.writeFloat(f32, self.stretch);
		writer.writeFloat(f32, self.age);
		writer.writeFloat(f32, self.growTime);
		writer.writeFloat(f32, self.lifetime);
	}

	/// Returns null when the cloud type is unknown to this side, which can happen
	/// if the server has assets the client does not. The region is skipped then
	/// rather than being drawn as the wrong kind of weather.
	pub fn read(reader: *main.utils.BinaryReader) !?Region {
		const id = try reader.readSliceWithSize();
		const typeIndex = CloudType.indexOf(id);
		const resolved = typeIndex orelse CloudType.emptyIndex;
		const region: Region = .{
			.typeIndex = resolved,
			.orderWeight = CloudType.get(resolved).spawning.orderWeight,
			.pos = .{try reader.readFloat(f64), try reader.readFloat(f64)},
			.direction = .{try reader.readFloat(f32), try reader.readFloat(f32)},
			.velocity = .{try reader.readFloat(f32), try reader.readFloat(f32)},
			.maxSpeed = try reader.readFloat(f32),
			.acceleration = try reader.readFloat(f32),
			.initialRadius = try reader.readFloat(f32),
			.radius = try reader.readFloat(f32),
			.rotation = try reader.readFloat(f32),
			.stretch = try reader.readFloat(f32),
			.age = try reader.readFloat(f32),
			.growTime = try reader.readFloat(f32),
			.lifetime = try reader.readFloat(f32),
		};
		if (typeIndex == null) return null;
		return region;
	}
};

// MARK: sampling

pub const Sample = struct {
	typeIndex: u32,
    /// 1 where a formation is at full strength, 0 where there is no weather.
	presence: f32,
};

/// Mirrors the compositing that `cloud_regions.comp` performs on the GPU, so
/// that both sides agree on which formation covers a point. Regions must be
/// ordered by ascending order weight.
pub fn sampleAt(regions: []const Region, pos: Vec2d) Sample {
	var typeIndex: u32 = CloudType.emptyIndex;
	var presence: f32 = 0;

	for (regions) |region| {
		if (region.radius <= 0) continue;

		const delta = pos - region.pos;
		const t = region.transform();
		// Column major mat2 times the offset vector.
		const transformed = Vec2d{
			t[0]*delta[0] + t[2]*delta[1],
			t[1]*delta[0] + t[3]*delta[1],
		};
		const distance: f32 = @floatCast(vec.length(transformed));

		if (distance > region.radius + 1.0/regionEdgeFadeFactor) continue;

		if (distance < region.radius) {
			const inner = @min((region.radius - distance)*regionEdgeFadeFactor, 1);
			if (typeIndex == region.typeIndex) {
				presence = presence + (1.0 - presence)*inner;
			} else {
				typeIndex = region.typeIndex;
				presence = inner;
			}
		} else {
			const outer = @min((distance - region.radius)*regionEdgeFadeFactor, 1);
			if (typeIndex != region.typeIndex) presence *= outer;
		}
	}

	return .{.typeIndex = typeIndex, .presence = presence};
}

pub const Precipitation = struct {
	weather: CloudType.Weather,
	/// From 0 to 1.
	amount: f32,

	pub const none: Precipitation = .{.weather = .none, .amount = 0};
};

/// What the formations overhead bring at a horizontal cloud space position,
/// ignoring anything the local terrain or biome has to say about it.
///
/// Rain only reaches the ground well inside a formation, so that a front brings
/// its weather in gradually instead of switching it on at its rim.
pub fn precipitationAt(regions: []const Region, pos: Vec2d) Precipitation {
	const rainThreshold = 0.7;
	const rainFade = 0.1;

	const sample = sampleAt(regions, pos);
	const kind = CloudType.get(sample.typeIndex).weather;
	if (kind == .none) return .none;

	const fade = 1 - sample.presence;
	return .{.weather = kind, .amount = std.math.clamp((rainThreshold - fade)/rainFade, 0, 1)};
}
