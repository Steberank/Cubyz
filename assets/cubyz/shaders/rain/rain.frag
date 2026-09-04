#version 460

layout(location = 0) in vec2 texCoords;
layout(location = 1) in float fade;
layout(location = 2) flat in vec3 light;

layout(location = 0) out vec4 fragColor;

layout(binding = 6) uniform sampler2D rainTexture;
layout(binding = 4) uniform sampler2D sceneDepth;

layout(location = 6) uniform vec3 rainColor;
/// How hard it is raining, from 0 to 1.
layout(location = 7) uniform float intensity;
layout(location = 8) uniform vec2 screenSize;

void main() {
	// Rain is drawn after the deferred pass, so that it is not fogged by the
	// distance of whatever terrain happens to be behind it. That leaves it
	// without a depth buffer to test against, hence the manual test.
	if(gl_FragCoord.z > texture(sceneDepth, gl_FragCoord.xy/screenSize).r) discard;

	float alpha = texture(rainTexture, texCoords).a*fade*intensity;
	if(alpha < 0.01) discard;
	fragColor = vec4(rainColor*light, alpha);
}
