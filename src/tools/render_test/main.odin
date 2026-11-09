package render_test

// Headless renderer check: draws the demo scene offscreen with SDL_GPU and
// writes a PNG. No window, no ImGui. Usage: render_test [out.png] [scale]

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

import "../../render"

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	out_path := len(os.args) > 1 ? os.args[1] : "build/render_test.png"
	scale: f32 = 1
	if len(os.args) > 2 {
		if v, ok := strconv.parse_f32(os.args[2]); ok do scale = v
	}

	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("SDL_Init failed:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.Quit()

	device := sdl.CreateGPUDevice({.SPIRV}, true, nil)
	if device == nil {
		fmt.eprintln("CreateGPUDevice failed:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyGPUDevice(device)
	log.infof("gpu driver: %s", sdl.GetGPUDeviceDriver(device))

	W := u32(960 * scale)
	H := u32(540 * scale)
	FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM

	r: render.Renderer
	if !render.init(&r, device, FORMAT) do os.exit(1)
	defer render.destroy(&r)

	target := sdl.CreateGPUTexture(device, {
		type = .D2, format = FORMAT, usage = {.COLOR_TARGET, .SAMPLER},
		width = W, height = H, layer_count_or_depth = 1, num_levels = 1,
	})
	defer sdl.ReleaseGPUTexture(device, target)

	download := sdl.CreateGPUTransferBuffer(device, {usage = .DOWNLOAD, size = W * H * 4})
	defer sdl.ReleaseGPUTransferBuffer(device, download)

	render.begin_frame(&r, render.view_matrix({f32(W), f32(H)}, {0, 0}, scale, 0))
	render.demo_scene(&r, 0.25 / scale)

	cmd := sdl.AcquireGPUCommandBuffer(device)
	render.upload(&r, cmd)
	pass := render.begin_scene_pass(&r, cmd, target, W, H, {0.2, 0.2, 0.22, 1})
	render.draw(&r, cmd, pass)
	sdl.EndGPURenderPass(pass)

	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUTexture(copy_pass,
		{texture = target, w = W, h = H, d = 1},
		{transfer_buffer = download})
	sdl.EndGPUCopyPass(copy_pass)

	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	_ = sdl.WaitForGPUFences(device, true, &fence, 1)
	sdl.ReleaseGPUFence(device, fence)

	pixels := sdl.MapGPUTransferBuffer(device, download, false)
	ok := stbi.write_png(fmt.ctprint(out_path), i32(W), i32(H), 4, pixels, i32(W * 4))
	sdl.UnmapGPUTransferBuffer(device, download)

	if ok == 0 {
		fmt.eprintln("failed to write", out_path)
		os.exit(1)
	}
	fmt.printfln("wrote %s (%dx%d, %d shapes, %d vertices, %d draw calls, msaa %v)",
		out_path, W, H, r.stats.shapes, r.stats.vertices, r.stats.draw_calls, r.samples)
}
