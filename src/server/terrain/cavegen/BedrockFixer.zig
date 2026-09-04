const main = @import("main");
const ZonElement = main.ZonElement;
const terrain = main.server.terrain;
const CaveMapFragment = terrain.CaveMap.CaveMapFragment;
const chunk = main.chunk;

pub const id = "cubyz:bedrock_fixer";

pub const priority = 524288;

pub const generatorSeed = 0xbed20c4f13d0;

pub const defaultState = .enabled;

pub fn init(parameters: ZonElement) void {
	_ = parameters;
}

pub fn generate(map: *CaveMapFragment, worldSeed: u64) void {
	_ = worldSeed;
	const relZ = chunk.worldMinZ -% map.pos.wz;
	const fragmentHeight = CaveMapFragment.height*map.pos.voxelSize;
	if (relZ < 0 or relZ >= fragmentHeight) return;

	const width = CaveMapFragment.width*map.pos.voxelSize;
	var x: u31 = 0;
	while (x < width) : (x += map.pos.voxelSize) {
		var y: u31 = 0;
		while (y < width) : (y += map.pos.voxelSize) {
			map.addRange(x, y, relZ, relZ + map.pos.voxelSize);
		}
	}
}
