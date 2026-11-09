#version 450
// Promation vector renderer: positions in world space, one transform per draw.
// SDL_GPU (SPIR-V) convention: vertex-stage uniform buffers live in set 1.

layout(location = 0) in vec2 a_pos;

layout(set = 1, binding = 0) uniform Vertex_Uniforms {
	mat4 u_world_to_clip;
};

void main() {
	gl_Position = u_world_to_clip * vec4(a_pos, 0.0, 1.0);
}
