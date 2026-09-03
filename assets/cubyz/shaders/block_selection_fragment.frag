#version 460

layout(location = 0) in vec3 mvVertexPos;

layout(location = 0) out vec4 fragColor;

layout(location = 6) uniform vec4 lineColor;

void main() {
	fragColor = lineColor;
}
