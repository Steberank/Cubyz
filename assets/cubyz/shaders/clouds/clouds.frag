#version 460

#include "frame_uniforms.glsl"

layout(location = 0) in vec3 worldPos;
layout(location = 1) in float brightness;
layout(location = 2) flat in vec3 faceNormal;
layout(location = 3) flat in float opacity;

layout(location = 0) out vec4 fragColor;

layout(location = 0) uniform vec3 ambientLight;
layout(location = 1) uniform vec2 screenSize;
layout(location = 2) uniform int skipDepthTests;

struct Fog {
	vec3 color;
	float density;
	float fogLower;
	float fogHigher;
};
layout(location = 6) uniform Fog fog;
layout(binding = 4) uniform sampler2D sceneDepth;

float densityIntegral(float dist, float zStart, float zDist, float fogLower, float fogHigher) {
	if (zDist < 0) {
		zStart += zDist;
		zDist = -zDist;
	}
	if (abs(zDist) < 0.001) {
		zDist = 0.001;
	}
	float beginLower = min(fogLower, zStart);
	float endLower = min(fogLower, zStart + zDist);
	float beginMid = max(fogLower, min(fogHigher, zStart));
	float endMid = max(fogLower, min(fogHigher, zStart + zDist));
	float midIntegral = -0.5*(endMid - fogHigher)*(endMid - fogHigher)/(fogHigher - fogLower) - -0.5*(beginMid - fogHigher)*(beginMid - fogHigher)/(fogHigher - fogLower);
	if (fogHigher == fogLower) midIntegral = 0;
	return (endLower - beginLower + midIntegral)/zDist*dist;
}

float calculateFogDistance(float dist, float zStart, float zScale, float fogDensity, float fogLower, float fogHigher) {
	float distCameraTerrain = densityIntegral(dist, zStart, zScale*dist, fogLower, fogHigher)*fogDensity;
	float distFromTerrain = -distCameraTerrain;
	if (distCameraTerrain < 10) {
		return distFromTerrain;
	} else if (distFromTerrain > -5 && dist != 0) {
		return distFromTerrain;
	} else {
		return -5;
	}
}

vec3 applyFrontfaceFog(float fogDistance, vec3 fogColor, vec3 inColor) {
	float fogFactor = exp(fogDistance);
	inColor *= fogFactor;
	inColor += fogColor;
	inColor -= fogColor*fogFactor;
	return inColor;
}

void main() {
	int bayerIndex = (int(gl_FragCoord.y)&3)*4 + (int(gl_FragCoord.x)&3);
	float bayerValues[16] = float[](
		0.03125, 0.53125, 0.15625, 0.65625,
		0.78125, 0.28125, 0.90625, 0.40625,
		0.21875, 0.71875, 0.09375, 0.59375,
		0.96875, 0.46875, 0.84375, 0.34375
	);
	if (opacity < 0.997 && bayerValues[bayerIndex] >= opacity) discard;

	if (skipDepthTests == 0) {
		vec2 uv = gl_FragCoord.xy/screenSize;
		if (gl_FragCoord.z > texture(sceneDepth, uv).r) discard;
	}

	float wrap = dot(normalize(faceNormal), vec3(0.35, 0.2, 0.9))*0.15 + 0.85;
	vec3 color = vec3(brightness)*wrap*pow(max(ambientLight, vec3(0.001)), vec3(2.4));
	float dist = length(worldPos);
	float zScale = dist > 0.001 ? worldPos.z/dist : 0.0;
	float fogDistance = calculateFogDistance(dist, playerPositionFraction.z, zScale, fog.density, fog.fogLower - playerPositionInteger.z, fog.fogHigher - playerPositionInteger.z);
	color = applyFrontfaceFog(fogDistance, fog.color, color);
	fragColor = vec4(color, 1.0);
}
