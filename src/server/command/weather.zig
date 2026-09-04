const std = @import("std");

const main = @import("main");
const Source = main.server.command.Source;
const CloudType = main.weather.CloudType;
const cloud = @import("cloud.zig");

pub const description = "Inspect or override the weather.";
pub const usage =
	\\/weather
	\\/weather clear
	\\/weather <cloud type id>
;

pub const Args = union(enum) {
	@"/weather <type>": struct { type: []const u8 },
	@"/weather": struct {},
};

pub fn execute(args: Args, source: Source) void {
	const world = main.server.world orelse {
		source.sendMessage("#ff0000No world is loaded.", .{});
		return;
	};

	switch (args) {
		.@"/weather" => {
			source.sendMessage("#ffff00{} cloud formation(s):", .{world.weather.regions.items.len});
			for (world.weather.regions.items) |region| {
				source.sendMessage("#ffff00  {s}: radius {d:.0} blocks, {d:.0}% through its life", .{
					CloudType.get(region.typeIndex).id,
					region.radius*main.weather.cloudScale,
					100*region.age/region.lifetime,
				});
			}
			cloud.listTypes(source);
		},
		.@"/weather <type>" => |params| {
			if (std.mem.eql(u8, params.type, "clear")) {
				world.weather.clearAll();
				source.sendMessage("#ffff00Cleared the weather.", .{});
				return;
			}
			cloud.reportSet(source, world.weather.setFromCommand(params.type, cloud.playerAnchor(source)), params.type);
		},
	}
}
