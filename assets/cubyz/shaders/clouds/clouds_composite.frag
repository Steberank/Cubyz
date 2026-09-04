#version 460

// Resolves the weighted blended transparency buffers onto the world.
// The result is emitted as (average colour, coverage) and blended with the usual
// source alpha blending, which reproduces `avg*(1 - revealage) + dst*revealage`.

#define EPSILON 0.00001

layout(location = 0) out vec4 fragColor;

layout(binding = 7) uniform sampler2D accumTexture;
layout(binding = 8) uniform sampler2D revealageTexture;

void main() {
	ivec2 uv = ivec2(gl_FragCoord.xy);
	float revealage = texelFetch(revealageTexture, uv, 0).r;
	if(revealage >= 1.0) discard;

	vec4 accum = texelFetch(accumTexture, uv, 0);
	if(isinf(max(max(abs(accum.r), abs(accum.g)), max(abs(accum.b), abs(accum.a))))) accum.rgb = vec3(accum.a);

	vec3 average = accum.rgb/max(accum.a, EPSILON);
	fragColor = vec4(average, 1.0 - revealage);
}
