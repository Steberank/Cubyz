#version 460

#include "frame_uniforms.glsl"

#ifdef OPEN_GL
#define gl_InstanceIndex gl_InstanceID
#endif

layout(location = 0) out vec3 worldPos;
layout(location = 1) out float brightness;
layout(location = 2) flat out vec3 faceNormal;
layout(location = 3) flat out float opacity;

struct SideInfo {
	int side;
	float x;
	float y;
	float z;
	float brightness;
	float radius;
	float opacity;
};

layout(std430, binding = 18) readonly buffer _sides {
	SideInfo data[];
} sides;

const vec2 corners[6] = vec2[6](
	vec2(-1, -1), vec2(1, -1), vec2(1, 1),
	vec2(-1, -1), vec2(1, 1), vec2(-1, 1)
);

void main() {
	SideInfo info = sides.data[gl_InstanceIndex];
	vec2 corner = corners[gl_VertexIndex];
	vec3 pos = vec3(info.x, info.y, info.z);
	vec3 normal = vec3(0);
	vec3 tangent = vec3(0);
	vec3 bitangent = vec3(0);
	if (info.side == 0) {
		normal = vec3(-1, 0, 0);
		tangent = vec3(0, 1, 0);
		bitangent = vec3(0, 0, 1);
	} else if (info.side == 1) {
		normal = vec3(1, 0, 0);
		tangent = vec3(0, 1, 0);
		bitangent = vec3(0, 0, 1);
	} else if (info.side == 2) {
		normal = vec3(0, -1, 0);
		tangent = vec3(1, 0, 0);
		bitangent = vec3(0, 0, 1);
	} else if (info.side == 3) {
		normal = vec3(0, 1, 0);
		tangent = vec3(1, 0, 0);
		bitangent = vec3(0, 0, 1);
	} else if (info.side == 4) {
		normal = vec3(0, 0, -1);
		tangent = vec3(1, 0, 0);
		bitangent = vec3(0, 1, 0);
	} else {
		normal = vec3(0, 0, 1);
		tangent = vec3(1, 0, 0);
		bitangent = vec3(0, 1, 0);
	}
	worldPos = pos + (tangent*corner.x + bitangent*corner.y + normal)*info.radius;
	brightness = info.brightness;
	faceNormal = normal;
	opacity = info.opacity;
	gl_Position = projectionMatrix*viewMatrix*vec4(worldPos, 1);
}
