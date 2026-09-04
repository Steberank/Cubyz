#version 460

layout(location = 0) in vec2 inTexCoords;

void main() {
	gl_Position = vec4(inTexCoords*2.0 - vec2(1.0), 0.0, 1.0);
}
