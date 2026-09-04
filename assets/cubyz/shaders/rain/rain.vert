#version 460

// One instanced quad per ground column around the player.
//
// The quad is billboarded around the vertical axis only, so the streaks stay
// upright however the camera is pitched. Its texture scrolls downwards over
// time, which is what makes the rain fall; nothing is simulated.

#include "../include/frame_uniforms.glsl"

#ifdef OPEN_GL
#define gl_InstanceIndex gl_InstanceID
#endif

layout(location = 0) in vec2 corner;

struct RainColumn {
	vec2 offset;
	float bottom;
	float top;
	/// Per column texture offset, so that every column does not show the same
	/// drops at the same height.
	vec2 phase;
	/// Per column fall speed multiplier, so the drops do not descend in lockstep.
	/// Kept subtle; the variety that matters comes from `phase`.
	float speed;
	float padding;
	/// Sky and block light already combined by the host. Only rgb is used.
	vec4 light;
};

layout(std430, binding = 30) readonly buffer _rainColumns {
	RainColumn columns[];
};

layout(location = 0) out vec2 texCoords;
layout(location = 1) out float fade;
layout(location = 2) flat out vec3 light;

/// Horizontal unit vector the quads are widened along, perpendicular to the
/// view direction so every quad faces the camera.
layout(location = 0) uniform vec2 rightVector;
layout(location = 1) uniform float halfWidth;
/// Seconds of rain so far. Scrolling is per column so that each one falls at its
/// own speed.
layout(location = 2) uniform float time;
/// Texture repeats per block, so the streaks keep their size when the quad does not.
layout(location = 3) uniform float repeatsPerBlock;
/// Rain keeps full strength out to `fadeRange.x` and only thins out past
/// `fadeRange.y`, so that its density looks the same nearby and in the distance.
layout(location = 4) uniform vec2 fadeRange;
/// Slants the streaks so the rain looks wind blown.
layout(location = 5) uniform vec2 slant;

void main() {
	RainColumn column = columns[gl_InstanceIndex];

	float height = column.top - column.bottom;
	float z = column.bottom + corner.y*height;

	// The slant grows with height so the bottom of the streak stays over the
	// column it belongs to.
	vec2 horizontal = column.offset + rightVector*(corner.x*halfWidth) + slant*(z - column.bottom);
	vec3 relativePos = vec3(horizontal, z);

	gl_Position = projectionMatrix*viewMatrix*vec4(relativePos, 1.0);

	// The vertical coordinate follows the world height rather than the quad, so
	// the drops keep their size and do not slide when the quad is resized.
	//
	// Scrolling has to be added, not subtracted: a drop sits wherever the
	// texture coordinate matches it, so growing the offset has to push it to a
	// lower world height for it to fall.
	texCoords = vec2(corner.x*0.5 + 0.5, z*repeatsPerBlock + time*column.speed) + column.phase;
	fade = 1.0 - smoothstep(fadeRange.x, fadeRange.y, length(column.offset));
	light = column.light.rgb;
}
