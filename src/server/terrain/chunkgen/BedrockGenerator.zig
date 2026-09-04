const main = @import("main");
const ZonElement = main.ZonElement;
const terrain = main.server.terrain;
const CaveMap = terrain.CaveMap;
const CaveBiomeMap = terrain.CaveBiomeMap;
const chunk = main.chunk;

pub const id = "cubyz:bedrock";

pub const priority = 524288;

pub const generatorSeed = 0xbed20c4f13e0;

pub const defaultState = .enabled;

var bedrock: main.blocks.Block = undefined;

pub fn init(parameters: ZonElement) void {
	_ = parameters;
	bedrock = main.blocks.parseBlock("cubyz:bedrock/bedrock");
}

pub fn generate(_: u64, ch: *main.chunk.ServerChunk, _: CaveMap.CaveMapView, _: CaveBiomeMap.CaveBiomeMapView) void {
	const voxelSize = ch.super.pos.voxelSize;
	const relZ = chunk.worldMinZ -% ch.super.pos.wz;
	if (relZ < 0 or relZ >= ch.super.width) return;
	const z = ch.startIndex(relZ);
	if (z < 0 or z >= ch.super.width) return;

	var x: u31 = 0;
	while (x < ch.super.width) : (x += voxelSize) {
		var y: u31 = 0;
		while (y < ch.super.width) : (y += voxelSize) {
			ch.updateBlockInGeneration(x, y, z, bedrock);
		}
	}
}
