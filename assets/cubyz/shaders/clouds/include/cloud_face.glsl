// Shared description of a single exposed cloud voxel face.
//
// Faces are indexed -X, +X, -Y, +Y, -Z, +Z. Cubyz is Z-up, so 4 and 5 are the
// bottom and top faces. The base mesh is the -X quad (x == -1, y and z in
// [-1, 1]); `cloudFaceTransforms` rotates it onto any of the six faces.

struct SideInfo {
	int side;
	float x;
	float y;
	float z;
	float brightness;
	float radius;
};

const vec3 cloudFaceNormals[6] = vec3[6](
	vec3(-1.0, 0.0, 0.0),
	vec3(1.0, 0.0, 0.0),
	vec3(0.0, -1.0, 0.0),
	vec3(0.0, 1.0, 0.0),
	vec3(0.0, 0.0, -1.0),
	vec3(0.0, 0.0, 1.0)
);

const mat3 cloudFaceTransforms[6] = mat3[6](
	mat3(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0),
	mat3(-1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0),
	mat3(0.0, 1.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 1.0),
	mat3(0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0),
	mat3(0.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 0.0),
	mat3(0.0, 0.0, -1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0)
);
