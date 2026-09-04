#version 460

#include "../include/frame_uniforms.glsl"

#ifdef OPEN_GL
#define gl_InstanceIndex gl_InstanceID
#endif

layout(location = 0) in vec3 position;

struct TransparentCubeInfo {
	float x;
	float y;
	float z;
	float brightness;
	float alpha;
	float radius;
};

layout(std430, binding = 25) readonly buffer _transparentCubeInfo {
	TransparentCubeInfo transparentCubes[];
};

layout(location = 0) out vec4 vertexColor;
layout(location = 1) out float fogDistance;
layout(location = 2) out float vertexDistance;

layout(location = 0) uniform vec3 cloudOffset;
layout(location = 1) uniform float cloudScale;
layout(location = 4) uniform vec3 darknessColorModifier;
/// Start of the drawn chunk's slice of the shared cube buffer.
layout(location = 6) uniform int firstElement;

void main() {
	TransparentCubeInfo info = transparentCubes[firstElement + gl_InstanceIndex];

	vec3 cloudPos = position*info.radius + vec3(info.x, info.y, info.z);
	vec3 relativePos = cloudPos*cloudScale + cloudOffset;

	gl_Position = projectionMatrix*viewMatrix*vec4(relativePos, 1.0);
	fogDistance = length(relativePos.xy);
	vertexDistance = length(relativePos);

	vertexColor = vec4(mix(darknessColorModifier, vec3(1.0), info.brightness), info.alpha);
}
