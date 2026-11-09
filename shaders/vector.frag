#version 450
// Flat colour, output premultiplied (blend: ONE, ONE_MINUS_SRC_ALPHA).
// SDL_GPU (SPIR-V) convention: fragment-stage uniform buffers live in set 3.

layout(location = 0) out vec4 o_color;

layout(set = 3, binding = 0) uniform Fragment_Uniforms {
	vec4 u_color; // straight (non-premultiplied) RGBA
};

void main() {
	o_color = vec4(u_color.rgb * u_color.a, u_color.a);
}
