//! GPU server: waits for requests in the shared ring, renders the vertex list with the
//! Metal-style runtime (metal2vulkan) on the phone Vulkan GPU, and writes RGBA8 pixels back.
#[path = "../ring.rs"]
mod ring;
use metal2vulkan::metal::{PixelFormat, PrimitiveType, TextureUsage};
use metal2vulkan::pipeline::{ColorAttachmentDescriptor, RenderPipelineDescriptor, StageSource};
use metal2vulkan_runtime::*;
use ring::*;
use std::time::{Duration, Instant};

type R<T> = Result<T, Box<dyn std::error::Error>>;

fn main() -> R<()> {
    let bc = std::fs::read(std::env::args().nth(1).unwrap_or("/data/local/tmp/fixture.bc".into()))?;
    let device = Device::system_default()?;
    println!("device: {}", device.name());
    let lib = device.new_library_with_compile_library(metal2vulkan::library::Library::from_air(&bc)?);
    let vertex = lib.new_function_with_name("colored_vertex")?;
    let fragment = lib.new_function_with_name("colored_fragment")?;
    let mut d = RenderPipelineDescriptor::new(StageSource::Function(vertex.function_descriptor()));
    d.fragment = Some(StageSource::Function(fragment.function_descriptor()));
    d.color_attachments[0] = Some(ColorAttachmentDescriptor::new(PixelFormat::RGBA8Unorm));
    let state = device.new_render_pipeline_state(&d, &PipelineOptions::default())?;
    let queue = device.new_command_queue()?;

    let ring = Ring::open(true);
    ring.store(MAGIC_W, MAGIC);
    ring.store(REQ, 0);
    ring.store(DONE, 0);
    println!("ring ready");
    let mut size = (0usize, 0usize);
    let mut target = None;
    let mut readback = None;
    let mut last = 0u32;
    loop {
        let req = ring.load(REQ);
        if req == last {
            std::thread::sleep(Duration::from_millis(2));
            continue;
        }
        let t0 = Instant::now();
        let (w, h) = (ring.load(WIDTH) as usize, ring.load(HEIGHT) as usize);
        let n = (ring.load(NVERTS) as usize).min(MAX_VERTS);
        if w == 0 || h == 0 || w > MAX_W || h > MAX_H {
            last = req;
            ring.store(DONE, req);
            continue;
        }
        if size != (w, h) {
            let mut t = TextureDescriptor::texture_2d(PixelFormat::RGBA8Unorm, w as u64, h as u64, false);
            t.usage = TextureUsage::RENDER_TARGET;
            t.resource_options = ResourceOptions::private();
            target = Some(device.new_texture(&t)?);
            readback = Some(device.new_buffer((w * h * 4) as u64, ResourceOptions::shared())?);
            size = (w, h);
        }
        let (target, readback) = (target.as_ref().unwrap(), readback.as_ref().unwrap());
        let mut vb = vec![0u8; n * 24];
        ring.read_bytes(VERT_OFF, &mut vb);
        let v: Vec<f32> = vb.chunks(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
        let mut pos = Vec::with_capacity(n * 8);
        let mut col = Vec::with_capacity(n * 16);
        for i in 0..n {
            for k in 0..2 {
                pos.extend_from_slice(&v[i * 6 + k].to_le_bytes());
            }
            for k in 2..6 {
                col.extend_from_slice(&v[i * 6 + k].to_le_bytes());
            }
        }
        let c = ring.load(CLEAR);
        let cc = |s: u32| ((c >> s) & 255) as f64 / 255.0;
        let mut pass = RenderPassDescriptor::new();
        let a = &mut pass.color_attachments[0];
        a.texture = Some(target.clone());
        a.load_action = LoadAction::Clear;
        a.store_action = StoreAction::Store;
        a.clear_color = ClearColor::new(cc(0), cc(8), cc(16), cc(24));
        let cb = queue.command_buffer()?;
        let mut enc = cb.render_command_encoder(&pass)?;
        enc.set_render_pipeline_state(&state)?;
        if n >= 3 {
            let pb = device.new_buffer_with_bytes(&pos, ResourceOptions::shared())?;
            let cbuf = device.new_buffer_with_bytes(&col, ResourceOptions::shared())?;
            enc.set_vertex_buffer(Some(&pb), 0, 0)?;
            enc.set_vertex_buffer(Some(&cbuf), 0, 1)?;
            enc.draw_primitives(PrimitiveType::Triangle, 0, n as u32, 1, 0)?;
        }
        enc.end_encoding()?;
        let mut blit = cb.blit_command_encoder()?;
        let row = (w * 4) as u64;
        blit.copy_from_texture_to_buffer(target, 0, 0, Origin::new(0, 0, 0), Size::new(w as u64, h as u64, 1), readback, 0, row, row * h as u64, BlitOption::None)?;
        blit.end_encoding()?;
        cb.commit()?;
        cb.wait_until_completed_for(Duration::from_secs(10)).map_err(|_| "gpu timeout")?;
        let src = readback.contents().ok_or("no contents")?;
        let px = unsafe { std::slice::from_raw_parts(src.as_ptr(), w * h * 4) };
        ring.write_bytes(PIX_OFF, px);
        ring.store(GPU_US, t0.elapsed().as_micros() as u32);
        last = req;
        ring.store(DONE, req);
    }
}
