#version 460

// Weighted blended order independent transparency for the soft shell that
// surrounds the opaque cloud surface.
// https://jcgt.org/published/0002/02/09/paper.pdf

layout(location = 0) in vec4 vertexColor;
layout(location = 1) in float fogDistance;
layout(location = 2) in float vertexDistance;

layout(location = 0) out vec4 accumColor;
layout(location = 1) out float revealage;

layout(binding = 6) uniform sampler2D bayerMatrix;

layout(location = 10) uniform vec4 colorModulator;
layout(location = 11) uniform float ditherScale;
layout(location = 12) uniform float fogStart;
layout(location = 13) uniform float fogEnd;
layout(location = 14) uniform vec3 fogColor;

void main() {
	float fade = colorModulator.a;
	if(fade < texture(bayerMatrix, gl_FragCoord.xy*ditherScale).r) discard;

	vec3 color = vertexColor.rgb*colorModulator.rgb;
	color = mix(color, fogColor, smoothstep(fogStart, fogEnd, fogDistance));

	vec4 premultiplied = vec4(color*vertexColor.a, vertexColor.a);
	float z = min(vertexDistance/1000.0, 1.0);
	float weight = max(premultiplied.a*3000.0*pow(1.0 - z, 3.0), 0.01);

	accumColor = premultiplied*weight;
	revealage = premultiplied.a;
}
