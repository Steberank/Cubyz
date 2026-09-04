#version 460

layout(location = 0) in vec4 vertexColor;
layout(location = 1) in float fogDistance;

layout(location = 0) out vec4 fragColor;

layout(binding = 6) uniform sampler2D bayerMatrix;

layout(location = 10) uniform vec4 colorModulator;
layout(location = 11) uniform float ditherScale;
layout(location = 12) uniform float fogStart;
layout(location = 13) uniform float fogEnd;
layout(location = 14) uniform vec3 fogColor;

void main() {
	// Freshly generated chunks fade in. Dithering the alpha keeps the clouds
	// fully opaque, so they can stay in the depth buffer while fading.
	float fade = colorModulator.a;
	if(fade < texture(bayerMatrix, gl_FragCoord.xy*ditherScale).r) discard;

	vec3 color = vertexColor.rgb*colorModulator.rgb;
	color = mix(color, fogColor, smoothstep(fogStart, fogEnd, fogDistance));
	fragColor = vec4(color, 1.0);
}
