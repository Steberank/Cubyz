//! Authoritative weather simulation.
//!
//! The server owns the list of cloud formations: it spawns them, moves them and
//! retires them, then broadcasts the result. Clients never invent weather of
//! their own, they only interpolate between the snapshots they are sent, which
//! is what keeps every player under the same sky.

const std = @import("std");

const main = @import("main");
const random = main.random;
const vec = main.vec;
const Vec2d = vec.Vec2d;
const Vec2f = vec.Vec2f;
const ZonElement = main.ZonElement;

const weather = main.weather;
const CloudType = weather.CloudType;
const Region = weather.Region;

/// Formations spawn within this distance of a player, in blocks. They are much
/// wider than that, so one of them covers everything the player can see.
const spawnRadiusBlocks: f64 = 10000;
/// Keeps formations from piling up on top of each other, in blocks.
const minSpawnDistanceBlocks: f32 = 500;
const spawnAttempts = 10;
const initialFormations = 3;
/// How far past a storm's edge the player should stand when one is summoned, in
/// blocks. A formation of radius 5000 then has its centre 6000 blocks away, so
/// the player is under the approaching rim rather than the core.
const commandStormMarginBlocks: f32 = 1000;
/// Fair-weather commands fill the sky with several overlapping formations.
const commandFairCount: usize = 5;

/// A formation is around for one and a half to two days, most of which it spends
/// at or near full size.
const minLifetime = 1.5*weather.dayLength;
const maxLifetime = 2.0*weather.dayLength;
const minGrowTime = 0.2*weather.dayLength;
const maxGrowTime = 0.4*weather.dayLength;
/// New formations appear far more often than they expire, so several of them
/// overlap and the weather does not swing between extremes.
const minSpawnInterval = 0.1*weather.dayLength;
const maxSpawnInterval = 0.5*weather.dayLength;

pub const Weather = struct {
	regions: main.ListManaged(Region),
	seed: u64,
	secondsUntilNextSpawn: f32 = 0,
	/// A fresh world starts with no weather at all, which would leave the sky
	/// empty until the first formation happened to spawn. It gets seeded with
	/// plausible weather on its first update instead.
	populated: bool = false,
	/// Set whenever the formation list changes, so that joining or expiring
	/// weather reaches clients immediately instead of at the next periodic
	/// broadcast.
	dirty: bool = true,

	pub fn init(worldSeed: u64) Weather {
		return .{
			.regions = .init(main.globalAllocator),
			.seed = worldSeed ^ 0x5c10_11d5,
		};
	}

	pub fn deinit(self: *Weather) void {
		self.regions.deinit();
	}

	fn randomRange(self: *Weather, min: f32, max: f32) f32 {
		if (max <= min) return min;
		return min + (max - min)*random.nextFloat(&self.seed);
	}

	/// Picks a cloud type with probability proportional to its spawn weight.
	fn pickType(self: *Weather) ?u32 {
		var totalWeight: f32 = 0;
		for (CloudType.all(), 0..) |cloudType, i| {
			if (i == CloudType.emptyIndex) continue;
			totalWeight += cloudType.spawning.weight;
		}
		if (totalWeight <= 0) return null;

		var target = random.nextFloat(&self.seed)*totalWeight;
		for (CloudType.all(), 0..) |cloudType, i| {
			if (i == CloudType.emptyIndex) continue;
			target -= cloudType.spawning.weight;
			if (target <= 0) return @intCast(i);
		}
		return null;
	}

	fn makeRegion(self: *Weather, typeIndex: u32, playerPos: Vec2d, spawnPos: Vec2d, allowGrowTime: bool, radiusBlocks: ?f32) Region {
		const spawning = CloudType.get(typeIndex).spawning;

		const deltaAdjust: f32 = if (spawning.movesTowardsPlayer) 0.1 else 1.0;
		const toPlayer = playerPos - spawnPos;
		const delta = Vec2f{
			@as(f32, @floatCast(toPlayer[0]))*(1.0 + random.nextFloat(&self.seed)*deltaAdjust),
			@as(f32, @floatCast(toPlayer[1]))*(1.0 + random.nextFloat(&self.seed)*deltaAdjust),
		};

		// One in five formations drifts in a random direction instead of towards
		// the player, so the weather does not always arrive head on.
		const direction = if (random.nextIntBounded(u32, &self.seed, 5) == 0)
			vec.normalize(Vec2f{random.nextFloatSigned(&self.seed), random.nextFloatSigned(&self.seed)} + Vec2f{1e-6, 0})
		else
			vec.normalize(delta + Vec2f{1e-6, 0});

		const lifetime = self.randomRange(minLifetime, maxLifetime);
		// Formations that were already there when the world loaded start at full
		// size instead of growing in front of the player.
		const growTime = if (allowGrowTime) @min(self.randomRange(minGrowTime, maxGrowTime), lifetime) else 0;
		const initialRadius = (radiusBlocks orelse self.randomRange(spawning.minRadius, spawning.maxRadius))/weather.cloudScale;

		return .{
			.typeIndex = typeIndex,
			.pos = spawnPos,
			.direction = direction,
			.velocity = .{0, 0},
			.maxSpeed = self.randomRange(spawning.minSpeed, spawning.maxSpeed)/weather.cloudScale,
			.acceleration = 32.0/weather.cloudScale,
			.initialRadius = initialRadius,
			.radius = 0,
			.rotation = std.math.atan2(delta[0], delta[1]) + std.math.pi,
			.stretch = @max(0.01, self.randomRange(spawning.minStretch, spawning.maxStretch)),
			.orderWeight = spawning.orderWeight,
			.age = 0,
			.growTime = growTime,
			.lifetime = lifetime,
		};
	}

	fn createRegion(self: *Weather, typeIndex: u32, playerPos: Vec2d, spawnPos: Vec2d, allowGrowTime: bool) ?Region {
		for (self.regions.items) |other| {
			const distance = vec.length(spawnPos - other.pos)*weather.cloudScale - other.radius*weather.cloudScale;
			if (distance <= minSpawnDistanceBlocks) return null;
		}
		return self.makeRegion(typeIndex, playerPos, spawnPos, allowGrowTime, null);
	}

	fn randomSpawnPos(self: *Weather, playerPos: Vec2d) Vec2d {
		const angle = random.nextDouble(&self.seed)*2*std.math.pi;
		const distance = @sqrt(random.nextDouble(&self.seed))*spawnRadiusBlocks/weather.cloudScale;
		return playerPos + Vec2d{@cos(angle)*distance, @sin(angle)*distance};
	}

	fn trySpawn(self: *Weather, playerPos: Vec2d, allowGrowTime: bool) bool {
		if (self.regions.items.len >= weather.maxFormations) return false;
		const typeIndex = self.pickType() orelse return false;

		for (0..spawnAttempts) |_| {
			const spawnPos = self.randomSpawnPos(playerPos);
			if (self.createRegion(typeIndex, playerPos, spawnPos, allowGrowTime)) |region| {
				self.insertByOrderWeight(region);
				return true;
			}
		}
		return false;
	}

	/// Regions are composited in list order, so lower order weights have to come
	/// first for a heavier formation to win where two of them overlap.
	fn insertByOrderWeight(self: *Weather, region: Region) void {
		var index: usize = self.regions.items.len;
		for (self.regions.items, 0..) |other, i| {
			if (other.orderWeight > region.orderWeight) {
				index = i;
				break;
			}
		}
		self.regions.insert(index, region);
		self.dirty = true;
	}

	/// Advances the weather. `playerPos` is where new formations are spawned
	/// around, in cloud space.
	pub fn update(self: *Weather, playerPos: Vec2d, deltaTime: f32) void {
		if (!self.populated) {
			self.populated = true;
			self.populate(playerPos);
			return;
		}

		var i: usize = 0;
		while (i < self.regions.items.len) {
			self.regions.items[i].advance(deltaTime);
			if (self.regions.items[i].isDead() or CloudType.get(self.regions.items[i].typeIndex).layers.len == 0) {
				_ = self.regions.orderedRemove(i);
				self.dirty = true;
			} else {
				i += 1;
			}
		}

		self.secondsUntilNextSpawn -= deltaTime;
		if (self.secondsUntilNextSpawn <= 0) {
			self.secondsUntilNextSpawn = self.randomRange(minSpawnInterval, maxSpawnInterval);
			_ = self.trySpawn(playerPos, true);
		}
	}

	/// Fills a fresh world with the weather it would plausibly already have.
	fn populate(self: *Weather, playerPos: Vec2d) void {
		self.secondsUntilNextSpawn = self.randomRange(minSpawnInterval, maxSpawnInterval);
		for (0..initialFormations) |_| _ = self.trySpawn(playerPos, false);
	}

	pub fn clearAll(self: *Weather) void {
		self.regions.clearRetainingCapacity();
		self.secondsUntilNextSpawn = self.randomRange(minSpawnInterval, maxSpawnInterval);
		self.populated = true;
		self.dirty = true;
	}

	pub const SetResult = union(enum) {
		unknown_type,
		fair: struct { id: []const u8, count: usize },
		storm: struct { id: []const u8, centerBlocks: Vec2d, radiusBlocks: f32 },
	};

	/// Replaces the current weather with the given cloud type. Storms and rain
	/// decks are placed so their centre sits beyond the player and their rim is
	/// nearby; fair types fill the sky with several overlapping formations.
	pub fn setFromCommand(self: *Weather, typeId: []const u8, playerBlockPos: Vec2d) SetResult {
		const typeIndex = CloudType.indexOf(typeId) orelse return .unknown_type;
		if (typeIndex == CloudType.emptyIndex) return .unknown_type;

		const cloudType = CloudType.get(typeIndex);
		const playerCloudPos = playerBlockPos/@as(Vec2d, @splat(weather.cloudScale));

		self.regions.clearRetainingCapacity();
		self.populated = true;
		self.secondsUntilNextSpawn = self.randomRange(minSpawnInterval, maxSpawnInterval);

		switch (cloudType.weather) {
			.none => {
				var spawned: usize = 0;
				const count: f64 = @floatFromInt(commandFairCount);
				for (0..commandFairCount) |i| {
					const angle = (@as(f64, @floatFromInt(i)) + random.nextDouble(&self.seed))*(2*std.math.pi)/count;
					const dist = (2000.0 + 2000.0*random.nextFloat(&self.seed))/weather.cloudScale;
					const spawnPos = playerCloudPos + Vec2d{@cos(angle)*dist, @sin(angle)*dist};
					var region = self.makeRegion(typeIndex, playerCloudPos, spawnPos, false, null);
					region.advance(0);
					self.insertByOrderWeight(region);
					spawned += 1;
				}
				return .{.fair = .{.id = cloudType.id, .count = spawned}};
			},
			.rain, .thunderstorm => {
				const radiusBlocks = self.randomRange(cloudType.spawning.minRadius, cloudType.spawning.maxRadius);
				const centerDist = (radiusBlocks + commandStormMarginBlocks)/weather.cloudScale;
				const angle = random.nextDouble(&self.seed)*2*std.math.pi;
				const spawnPos = playerCloudPos + Vec2d{@cos(angle)*centerDist, @sin(angle)*centerDist};
				var region = self.makeRegion(typeIndex, playerCloudPos, spawnPos, false, radiusBlocks);
				const toPlayer = playerCloudPos - spawnPos;
				region.direction = vec.normalize(Vec2f{
					@floatCast(toPlayer[0]),
					@floatCast(toPlayer[1]),
				} + Vec2f{1e-6, 0});
				region.advance(0);
				self.insertByOrderWeight(region);
				return .{
					.storm = .{
						.id = cloudType.id,
						.centerBlocks = spawnPos*@as(Vec2d, @splat(weather.cloudScale)),
						.radiusBlocks = radiusBlocks,
					},
				};
			},
		}
	}

	pub fn toZon(self: *const Weather, allocator: main.heap.NeverFailingAllocator) ZonElement {
		const zon = ZonElement.initObject(allocator);
		zon.put("seed", self.seed);
		zon.put("secondsUntilNextSpawn", self.secondsUntilNextSpawn);
		zon.put("populated", self.populated);
		const list = ZonElement.initArray(allocator);
		for (self.regions.items) |region| list.array.append(region.toZon(allocator));
		zon.put("regions", list);
		return zon;
	}

	pub fn loadFromZon(self: *Weather, zon: ZonElement) void {
		self.seed = zon.get(u64, "seed") orelse self.seed;
		self.secondsUntilNextSpawn = zon.get(f32, "secondsUntilNextSpawn") orelse 0;
		self.populated = zon.get(bool, "populated") orelse false;
		self.regions.clearRetainingCapacity();
		for (zon.getChild("regions").toSlice()) |child| {
			if (self.regions.items.len >= weather.maxFormations) break;
			// Regions referring to cloud types that no longer exist are dropped.
			if (Region.fromZon(child)) |region| self.regions.append(region);
		}
		self.dirty = true;
	}

	pub fn write(self: *const Weather, writer: *main.utils.BinaryWriter) void {
		writer.writeInt(u8, @intCast(@min(self.regions.items.len, weather.maxFormations)));
		for (self.regions.items[0..@min(self.regions.items.len, weather.maxFormations)]) |region| {
			region.write(writer);
		}
	}
};
