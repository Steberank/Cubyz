#version 460

#include "../include/frame_uniforms.glsl"
#include "include/cloud_face.glsl"

#ifdef OPEN_GL
#define gl_InstanceIndex gl_InstanceID
#endif

layout(location = 0) in vec3 position;

layout(std430, binding = 22) readonly buffer _sideInfo {
	SideInfo sides[];
};

layout(location = 0) out vec4 vertexColor;
layout(location = 1) out float fogDistance;

/// Offset from the cloud chunk grid origin to the player, already including the
/// cloud layer height. Cloud space positions are kept small and relative so that
/// they stay precise no matter how far the player is from the world origin.
layout(location = 0) uniform vec3 cloudOffset;
layout(location = 1) uniform float cloudScale;
layout(location = 2) uniform float lightPower;
layout(location = 3) uniform float ambientLight;
layout(location = 4) uniform vec3 darknessColorModifier;
layout(location = 5) uniform bool useNormals;
/// Start of the drawn chunk's slice of the shared face buffer.
layout(location = 6) uniform int firstElement;

const vec3 diffuseLight0 = normalize(vec3(0.2, -0.7, 1.0));
const vec3 diffuseLight1 = normalize(vec3(-0.2, 0.7, 1.0));

vec4 mixLight(vec3 normal, vec4 color) {
	float light0 = max(0.0, dot(diffuseLight0, normal));
	float light1 = max(0.0, dot(diffuseLight1, normal));
	float lightAccum = min(1.0, (light0 + light1)*lightPower + ambientLight);
	// Leaving blue untouched tints the shaded faces towards the sky colour.
	return vec4(color.r*lightAccum, color.g*lightAccum, color.b, color.a);
}

void main() {
	SideInfo info = sides[firstElement + gl_InstanceIndex];

	vec3 localPos = cloudFaceTransforms[info.side]*position;
	vec3 cloudPos = localPos*info.radius + vec3(info.x, info.y, info.z);
	vec3 relativePos = cloudPos*cloudScale + cloudOffset;

	gl_Position = projectionMatrix*viewMatrix*vec4(relativePos, 1.0);
	fogDistance = length(relativePos.xy);

	vec4 baseColor = vec4(mix(darknessColorModifier, vec3(1.0), info.brightness), 1.0);
	vertexColor = useNormals ? mixLight(cloudFaceNormals[info.side], baseColor) : baseColor;
}
