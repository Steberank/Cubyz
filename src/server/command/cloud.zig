const main = @import("main");
const Source = main.server.command.Source;
const CloudType = main.weather.CloudType;
const Vec2d = main.vec.Vec2d;
const ServerWeather = @import("../weather.zig").Weather;

pub const description = "Inspect or override the cloud formations.";
pub const usage =
	\\/cloud
	\\/cloud clear
	\\/cloud set <cloud type>
;

pub const Args = union(enum) {
	@"/cloud <subcommand> <type>": struct { subcommand: enum { set }, type: []const u8 },
	@"/cloud <subcommand>": struct { subcommand: enum { clear } },
	@"/cloud": struct {},
};

pub fn listTypes(source: Source) void {
	var list: main.ListManaged(u8) = .init(main.stackAllocator);
	defer list.deinit();
	for (CloudType.all(), 0..) |cloudType, i| {
		if (i == CloudType.emptyIndex) continue;
		if (list.items.len != 0) list.appendSlice(", ");
		list.appendSlice(cloudType.id);
	}
	source.sendMessage("#ffff00Known cloud types: {s}", .{list.items});
}

pub fn playerAnchor(source: Source) Vec2d {
	const world = main.server.world.?;
	if (source == .user) {
		const pos = source.user.player().pos;
		return .{pos[0], pos[1]};
	}
	const userList = main.server.getUserList(main.stackAllocator);
	defer main.stackAllocator.free(userList);
	if (userList.len != 0) {
		const pos = userList[0].player().pos;
		return .{pos[0], pos[1]};
	}
	return .{@floatFromInt(world.spawn[0]), @floatFromInt(world.spawn[1])};
}

pub fn reportSet(source: Source, result: ServerWeather.SetResult, requested: []const u8) void {
	switch (result) {
		.unknown_type => {
			source.sendMessage("#ff0000There is no cloud type called '{s}'.", .{requested});
			listTypes(source);
		},
		.fair => |fair| source.sendMessage("#ffff00Cleared the sky and brought in {} {s} formation(s).", .{fair.count, fair.id}),
		.storm => |storm| source.sendMessage(
			"#ffff00{s} centre: {d:.0}, {d:.0} (radius {d:.0} blocks)",
			.{storm.id, storm.centerBlocks[0], storm.centerBlocks[1], storm.radiusBlocks},
		),
	}
}

pub fn execute(args: Args, source: Source) void {
	const world = main.server.world orelse {
		source.sendMessage("#ff0000No world is loaded.", .{});
		return;
	};

	switch (args) {
		.@"/cloud" => {
			source.sendMessage("#ffff00{} cloud formation(s):", .{world.weather.regions.items.len});
			for (world.weather.regions.items) |region| {
				source.sendMessage("#ffff00  {s}: radius {d:.0} blocks, {d:.0}% through its life", .{
					CloudType.get(region.typeIndex).id,
					region.radius*main.weather.cloudScale,
					100*region.age/region.lifetime,
				});
			}
			listTypes(source);
		},
		.@"/cloud <subcommand>" => {
			world.weather.clearAll();
			source.sendMessage("#ffff00Cleared the weather.", .{});
		},
		.@"/cloud <subcommand> <type>" => |params| {
			reportSet(source, world.weather.setFromCommand(params.type, playerAnchor(source)), params.type);
		},
	}
}
