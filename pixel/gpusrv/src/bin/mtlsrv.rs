//! Metal RPC server: executes Metal-style calls that a client (the iOS side) writes into the shared ring, with the
//! metal2vulkan runtime on the phone's Vulkan GPU. First slice: libraries, buffers, compute pipelines, dispatch.
//!
//! Mailbox at ring offset RPC_OFF (u32 words): 0 magic "MTL1", 1 request counter, 2 done counter, 3 status (0 = ok),
//! 4 op, 5 result id/value, 6 response payload length; request/response payload at RPC_OFF + 0x1000 (up to PAYLOAD_MAX).
//! Ops (all integers little endian u32 inside the payload):
//!  1 NEW_LIBRARY  payload = AIR bitcode or metallib bytes                       -> result = library id
//!  2 NEW_BUFFER   payload = u32 length, u32 has_init, [init bytes]               -> result = buffer id
//!  3 WRITE_BUFFER payload = u32 id, u32 offset, bytes
//!  4 READ_BUFFER  payload = u32 id, u32 offset, u32 length                       -> response payload = the bytes
//!  5 NEW_COMPUTE  payload = u32 library id, name bytes                           -> result = pipeline id, word 7 = max threads
//!  7 NEW_TEXTURE payload = u32 w, u32 h (RGBA8 render target)                  -> result = texture id
//!  8 NEW_RENDER  payload = u32 library id, u32 vertex-name length, vertex name, fragment name -> result = pipeline id
//!  9 RENDER      payload = u32 pso, u32 texture, f32 clear[4], u32 nvb, u32 primitive, u32 start, u32 count, nvb x (buffer id, index, offset)
//! 10 READ_TEXTURE payload = u32 texture id                                      -> response payload = RGBA8 pixels
//!  6 DISPATCH     payload = u32 pso, u32 nbufs, u32 grid[3], u32 tg[3], nbufs x (u32 buffer id, u32 index, u32 offset)
#[path = "../ring.rs"]
mod ring;
use metal2vulkan::metal::{BlendFactor, BlendOperation, ColorWriteMask, CompareFunction, CullMode, IndexType, PixelFormat, PrimitiveType, TextureType, TextureUsage, Winding};
use metal2vulkan::metal::state::{DepthStencilDescriptor, StencilDescriptor};
use metal2vulkan::metal::StencilOperation;
use metal2vulkan::bind::SamplerDescriptor;
use metal2vulkan::metal::{SamplerAddressMode, SamplerBorderColor, SamplerMinMagFilter, SamplerMipFilter};
use metal2vulkan::pipeline::{ColorAttachmentDescriptor, RenderPipelineDescriptor, StageSource};
use metal2vulkan_runtime::*;
use ring::*;
use std::collections::HashMap;
use std::time::Duration;

const RPC_OFF: usize = 0xB0_0000;
const PAYLOAD_OFF: usize = RPC_OFF + 0x1000;
const PAYLOAD_MAX: usize = 0x30_0000;

type R<T> = Result<T, Box<dyn std::error::Error>>;

fn u32at(b: &[u8], i: usize) -> u32 {
    u32::from_le_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]])
}

fn main() -> R<()> {
    let device = Device::system_default()?;
    println!("device: {}", device.name());
    let queue = device.new_command_queue()?;
    let ring = Ring::open(true);
    let w = |i: usize, v: u32| ring.write_bytes(RPC_OFF + i * 4, &v.to_le_bytes());
    let r = |i: usize| {
        let mut b = [0u8; 4];
        ring.read_bytes(RPC_OFF + i * 4, &mut b);
        u32::from_le_bytes(b)
    };
    w(1, 0);
    w(2, 0);
    w(0, 0x4d54_4c31);
    println!("mtl rpc ready");

    let mut libs: HashMap<u32, Library> = HashMap::new();
    let mut bufs: HashMap<u32, Buffer> = HashMap::new();
    let mut psos: HashMap<u32, ComputePipelineState> = HashMap::new();
    let mut rpsos: HashMap<u32, RenderPipelineState> = HashMap::new();
    let mut texs: HashMap<u32, (Texture, u64, u64)> = HashMap::new();
    let mut dss: HashMap<u32, DepthStencilState> = HashMap::new();
    let mut samplers: HashMap<u32, SamplerState> = HashMap::new();
    let mut ttypes: HashMap<u32, u32> = HashMap::new();
    let mut next = 1u32;
    let mut pres = 0u32;
    w(8, 0);
    let mut last = 0u32;
    loop {
        let req = r(1);
        if req == last {
            std::thread::sleep(Duration::from_millis(1));
            continue;
        }
        let op = r(4);
        let plen = (r(6) as usize).min(PAYLOAD_MAX);
        let mut p = vec![0u8; plen];
        if plen > 0 {
            ring.read_bytes(PAYLOAD_OFF, &mut p);
        }
        let mut status = 0u32;
        let mut result = 0u32;
        let mut extra = 0u32;
        let mut resp: Vec<u8> = Vec::new();
        let out: R<()> = (|| {
            match op {
                1 => {
                    let lib = if p.starts_with(b"MTLB") {
                        device.new_library_with_data(&p)?
                    } else {
                        device.new_library_with_compile_library(metal2vulkan::library::Library::from_air(&p)?)
                    };
                    libs.insert(next, lib);
                    result = next;
                    next += 1;
                }
                2 => {
                    let len = u32at(&p, 0) as u64;
                    let b = if u32at(&p, 4) != 0 {
                        device.new_buffer_with_bytes(&p[8..8 + len as usize], ResourceOptions::shared())?
                    } else {
                        device.new_buffer(len, ResourceOptions::shared())?
                    };
                    bufs.insert(next, b);
                    result = next;
                    next += 1;
                }
                3 => {
                    let (id, off) = (u32at(&p, 0), u32at(&p, 4) as usize);
                    let b = bufs.get(&id).ok_or("no such buffer")?;
                    let dst = b.contents().ok_or("buffer has no contents")?;
                    let data = &p[8..];
                    if off + data.len() > b.length() as usize {
                        return Err("write out of range".into());
                    }
                    unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), dst.as_ptr().add(off), data.len()) };
                }
                4 => {
                    let (id, off, len) = (u32at(&p, 0), u32at(&p, 4) as usize, u32at(&p, 8) as usize);
                    let b = bufs.get(&id).ok_or("no such buffer")?;
                    let src = b.contents().ok_or("buffer has no contents")?;
                    if off + len > b.length() as usize || len > PAYLOAD_MAX {
                        return Err("read out of range".into());
                    }
                    resp = unsafe { std::slice::from_raw_parts(src.as_ptr().add(off), len) }.to_vec();
                }
                5 => {
                    let lib = libs.get(&u32at(&p, 0)).ok_or("no such library")?;
                    let name = std::str::from_utf8(&p[4..])?;
                    let f = lib.new_function_with_name(name)?;
                    let st = device.new_compute_pipeline_state_with_function(&f, &PipelineOptions::default())?;
                    extra = st.max_total_threads_per_threadgroup() as u32;
                    psos.insert(next, st);
                    result = next;
                    next += 1;
                }
                6 => {
                    let st = psos.get(&u32at(&p, 0)).ok_or("no such pipeline")?;
                    let nb = u32at(&p, 4) as usize;
                    let grid = Size::new(u32at(&p, 8) as u64, u32at(&p, 12) as u64, u32at(&p, 16) as u64);
                    let tg = Size::new(u32at(&p, 20) as u64, u32at(&p, 24) as u64, u32at(&p, 28) as u64);
                    let cb = queue.command_buffer()?;
                    let mut enc = cb.compute_command_encoder()?;
                    enc.set_compute_pipeline_state(st)?;
                    for k in 0..nb {
                        let o = 32 + k * 12;
                        let b = bufs.get(&u32at(&p, o)).ok_or("no such buffer")?;
                        enc.set_buffer(Some(b), u32at(&p, o + 8) as u64, u32at(&p, o + 4))?;
                    }
                    {
                        let mut o = 32 + nb * 12;
                        if p.len() >= o + 4 {
                            let nt = u32at(&p, o) as usize;
                            o += 4;
                            for k in 0..nt {
                                let (t, _, _) = texs.get(&u32at(&p, o + k * 8)).ok_or("no such compute texture")?;
                                enc.set_texture(Some(t), u32at(&p, o + k * 8 + 4))?;
                            }
                            o += nt * 8;
                        }
                        if p.len() >= o + 4 {
                            let ntg = u32at(&p, o) as usize;
                            o += 4;
                            for k in 0..ntg {
                                enc.set_threadgroup_memory_length(u32at(&p, o + k * 8), u32at(&p, o + k * 8 + 4))?;
                            }
                        }
                    }
                    enc.dispatch_threads(grid, tg)?;
                    enc.end_encoding()?;
                    cb.commit()?;
                    cb.wait_until_completed_for(Duration::from_secs(20)).map_err(|_| "gpu timeout")?;
                }
                7 => {
                    let (tw, th) = (u32at(&p, 0) as u64, u32at(&p, 4) as u64);
                    let depth = p.len() >= 16 && u32at(&p, 12) >= 1;
                    let dsfmt = if p.len() >= 16 && u32at(&p, 12) == 2 { PixelFormat::Depth32FloatStencil8 } else { PixelFormat::Depth32Float };
                    let mut t = TextureDescriptor::texture_2d(if depth { dsfmt } else { PixelFormat::RGBA8Unorm }, tw, th, p.len() >= 20 && u32at(&p, 16) == 1);
                    let samples = if p.len() >= 24 { u32at(&p, 20) as u64 } else { 1 };
                    t.usage = if p.len() >= 12 && u32at(&p, 8) & 1 != 0 { TextureUsage::RENDER_TARGET | TextureUsage::SHADER_READ } else { TextureUsage::RENDER_TARGET };
                    if p.len() >= 12 && u32at(&p, 8) & 2 != 0 {
                        t.usage = t.usage | TextureUsage::SHADER_WRITE;
                    }
                    let ttype = if p.len() >= 36 { u32at(&p, 24) } else { 2 };
                    if samples <= 1 && p.len() >= 36 {
                        let tt = TextureType::try_from(ttype)?;
                        t.texture_type = tt;
                        t.depth = u32at(&p, 28).max(1) as u64;
                        t.array_length = u32at(&p, 32).max(1) as u64;
                    }
                    if samples > 1 {
                        t.texture_type = TextureType::Type2DMultisample;
                        t.sample_count = samples;
                        t.usage = TextureUsage::RENDER_TARGET;
                    }
                    t.resource_options = ResourceOptions::private();
                    texs.insert(next, (device.new_texture(&t)?, tw, th));
                    ttypes.insert(next, ttype);
                    result = next;
                    next += 1;
                }
                8 => {
                    let lib = libs.get(&u32at(&p, 0)).ok_or("no such library")?;
                    let vl = u32at(&p, 4) as usize;
                    let vname = std::str::from_utf8(&p[8..8 + vl])?;
                    let fname = std::str::from_utf8(&p[8 + vl..])?;
                    let vf = lib.new_function_with_name(vname)?;
                    let ff = lib.new_function_with_name(fname)?;
                    let mut d = RenderPipelineDescriptor::new(StageSource::Function(vf.function_descriptor()));
                    d.fragment = Some(StageSource::Function(ff.function_descriptor()));
                    d.color_attachments[0] = Some(ColorAttachmentDescriptor::new(PixelFormat::RGBA8Unorm));
                    rpsos.insert(next, device.new_render_pipeline_state(&d, &PipelineOptions::default())?);
                    result = next;
                    next += 1;
                }
                9 => {
                    let st = rpsos.get(&u32at(&p, 0)).ok_or("no such render pipeline")?;
                    let (tex, _, _) = texs.get(&u32at(&p, 4)).ok_or("no such texture")?;
                    let f = |i: usize| f32::from_bits(u32at(&p, i)) as f64;
                    let (nvb, prim, start, count) = (u32at(&p, 24) as usize, u32at(&p, 28), u32at(&p, 32) as u64, u32at(&p, 36));
                    let mut pass = RenderPassDescriptor::new();
                    let a = &mut pass.color_attachments[0];
                    a.texture = Some(tex.clone());
                    a.load_action = LoadAction::Clear;
                    a.store_action = StoreAction::Store;
                    a.clear_color = ClearColor::new(f(8), f(12), f(16), f(20));
                    let cb = queue.command_buffer()?;
                    let mut enc = cb.render_command_encoder(&pass)?;
                    enc.set_render_pipeline_state(st)?;
                    for k in 0..nvb {
                        let o = 40 + k * 12;
                        let b = bufs.get(&u32at(&p, o)).ok_or("no such buffer")?;
                        enc.set_vertex_buffer(Some(b), u32at(&p, o + 8) as u64, u32at(&p, o + 4))?;
                    }
                    let pt = match prim {
                        0 => PrimitiveType::Point,
                        1 => PrimitiveType::Line,
                        2 => PrimitiveType::LineStrip,
                        4 => PrimitiveType::TriangleStrip,
                        _ => PrimitiveType::Triangle,
                    };
                    enc.draw_primitives(pt, start as u32, count, 1, 0)?;
                    enc.end_encoding()?;
                    cb.commit()?;
                    cb.wait_until_completed_for(Duration::from_secs(20)).map_err(|_| "gpu timeout")?;
                }
                10 => {
                    let (tex, tw0, th0) = texs.get(&u32at(&p, 0)).ok_or("no such texture")?;
                    let level = if p.len() >= 8 { u32at(&p, 4) as u64 } else { 0 };
                    let (tw, th) = ((tw0 >> level).max(1), (th0 >> level).max(1));
                    let (y0, th) = if p.len() >= 16 && u32at(&p, 12) != 0 { (u32at(&p, 8) as u64, u32at(&p, 12) as u64) } else { (0, th) };
                    let kind = ttypes.get(&u32at(&p, 0)).copied().unwrap_or(2);
                    let (rslice, rz) = if p.len() >= 24 { (u32at(&p, 16) as u64, u32at(&p, 20) as u64) } else { (0, 0) };
                    let (rslice, rz) = if kind == 7 { (0, rz) } else { (rslice, 0) };
                    let row = tw * 4;
                    let rb = device.new_buffer(row * th, ResourceOptions::shared())?;
                    let cb = queue.command_buffer()?;
                    let mut blit = cb.blit_command_encoder()?;
                    blit.copy_from_texture_to_buffer(tex, rslice, level, Origin::new(0, y0, rz), Size::new(tw, th, 1), &rb, 0, row, row * th, BlitOption::None)?;
                    blit.end_encoding()?;
                    cb.commit()?;
                    cb.wait_until_completed_for(Duration::from_secs(20)).map_err(|_| "gpu timeout")?;
                    let src = rb.contents().ok_or("no contents")?;
                    resp = unsafe { std::slice::from_raw_parts(src.as_ptr(), (row * th) as usize) }.to_vec();
                }
                11 => {
                    // PRESENT: texture id, x, y -> pixels into the ring's pixel area, then the present counter (XNU pastes them)
                    let (tex, tw, th) = texs.get(&u32at(&p, 0)).ok_or("no such texture")?;
                    let (ox, oy) = (u32at(&p, 4), u32at(&p, 8));
                    let row = tw * 4;
                    let rb = device.new_buffer(row * th, ResourceOptions::shared())?;
                    let cb = queue.command_buffer()?;
                    let mut blit = cb.blit_command_encoder()?;
                    blit.copy_from_texture_to_buffer(tex, 0, 0, Origin::new(0, 0, 0), Size::new(*tw, *th, 1), &rb, 0, row, row * th, BlitOption::None)?;
                    blit.end_encoding()?;
                    cb.commit()?;
                    cb.wait_until_completed_for(Duration::from_secs(20)).map_err(|_| "gpu timeout")?;
                    let src = rb.contents().ok_or("no contents")?;
                    let px = unsafe { std::slice::from_raw_parts(src.as_ptr(), (row * th) as usize) };
                    ring.write_bytes(PIX_OFF, px);
                    w(9, *tw as u32);
                    w(10, *th as u32);
                    w(11, ox);
                    w(12, oy);
                    pres += 1;
                    w(8, pres);
                }
                12 => {
                    // RENDER_EX: pso, texture, clear[4], load, nvb, prim, start, count, nft; nvb x (buffer, index, offset); nft x (texture, index)
                    let st = rpsos.get(&u32at(&p, 0)).ok_or("no such render pipeline")?;
                    let (tex, _, _) = texs.get(&u32at(&p, 4)).ok_or("no such texture")?;
                    let f = |i: usize| f32::from_bits(u32at(&p, i)) as f64;
                    let (load, nvb, prim, start, count, nft) =
                        (u32at(&p, 24), u32at(&p, 28) as usize, u32at(&p, 32), u32at(&p, 36) as u64, u32at(&p, 40), u32at(&p, 44) as usize);
                    let (nfb, idxbuf, idxoff, idxtype) = (u32at(&p, 48) as usize, u32at(&p, 52), u32at(&p, 56) as u64, u32at(&p, 60));
                    let (dtex_id, ds_id, cdepth, cull, wind, dload) =
                        (u32at(&p, 64), u32at(&p, 68), f32::from_bits(u32at(&p, 72)) as f64, u32at(&p, 76), u32at(&p, 80), u32at(&p, 84));
                    let (has_st, sref_f, sref_b, sclear, sload, resolve_id, ninst, binst, bvert, vis_id, vis_mode, vis_off) = {
                        let so = 88 + nvb * 12 + nft * 8 + nfb * 12;
                        let nfs = if p.len() >= so + 4 { u32at(&p, so) as usize } else { 0 };
                        let mut o = so + 4 + nfs * 8 + 48;
                        if p.len() >= o + 4 {
                            o += 4 + u32at(&p, o) as usize * 8;
                        }
                        if p.len() >= o + 4 {
                            o += 4 + u32at(&p, o) as usize * 8;
                        }
                        if p.len() >= o + 48 {
                            (u32at(&p, o) != 0, u32at(&p, o + 4), u32at(&p, o + 8), u32at(&p, o + 12), u32at(&p, o + 16), u32at(&p, o + 20),
                             u32at(&p, o + 24).max(1), u32at(&p, o + 28), u32at(&p, o + 32) as i32, u32at(&p, o + 36), u32at(&p, o + 40), u32at(&p, o + 44) as u64)
                        } else if p.len() >= o + 36 {
                            (u32at(&p, o) != 0, u32at(&p, o + 4), u32at(&p, o + 8), u32at(&p, o + 12), u32at(&p, o + 16), u32at(&p, o + 20),
                             u32at(&p, o + 24).max(1), u32at(&p, o + 28), u32at(&p, o + 32) as i32, 0, 0, 0)
                        } else if p.len() >= o + 24 {
                            (u32at(&p, o) != 0, u32at(&p, o + 4), u32at(&p, o + 8), u32at(&p, o + 12), u32at(&p, o + 16), u32at(&p, o + 20), 1, 0, 0, 0, 0, 0)
                        } else if p.len() >= o + 20 {
                            (u32at(&p, o) != 0, u32at(&p, o + 4), u32at(&p, o + 8), u32at(&p, o + 12), u32at(&p, o + 16), 0, 1, 0, 0, 0, 0, 0)
                        } else {
                            (false, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0)
                        }
                    };
                    let (tlevel, tslice) = {
                        let so = 88 + nvb * 12 + nft * 8 + nfb * 12;
                        let nfs = if p.len() >= so + 4 { u32at(&p, so) as usize } else { 0 };
                        let mut o = so + 4 + nfs * 8 + 48;
                        if p.len() >= o + 4 {
                            o += 4 + u32at(&p, o) as usize * 8;
                        }
                        if p.len() >= o + 4 {
                            o += 4 + u32at(&p, o) as usize * 8;
                        }
                        if p.len() >= o + 56 {
                            (u32at(&p, o + 48) as u64, u32at(&p, o + 52) as u64)
                        } else {
                            (0, 0)
                        }
                    };
                    let mut pass = RenderPassDescriptor::new();
                    let a = &mut pass.color_attachments[0];
                    a.level = tlevel;
                    a.slice = tslice;
                    a.texture = Some(tex.clone());
                    a.load_action = if load == 1 { LoadAction::Load } else { LoadAction::Clear };
                    a.store_action = StoreAction::Store;
                    a.clear_color = ClearColor::new(f(8), f(12), f(16), f(20));
                    if resolve_id != 0 {
                        let (rt, _, _) = texs.get(&resolve_id).ok_or("no such resolve texture")?;
                        a.resolve_texture = Some(rt.clone());
                        a.store_action = StoreAction::MultisampleResolve;
                    }
                    if dtex_id != 0 {
                        let (dt, _, _) = texs.get(&dtex_id).ok_or("no such depth texture")?;
                        pass.depth_attachment.texture = Some(dt.clone());
                        pass.depth_attachment.load_action = if dload == 1 { LoadAction::Load } else { LoadAction::Clear };
                        pass.depth_attachment.store_action = StoreAction::Store;
                        pass.depth_attachment.clear_depth = cdepth;
                        if has_st {
                            pass.stencil_attachment.texture = Some(dt.clone());
                            pass.stencil_attachment.load_action = if sload == 1 { LoadAction::Load } else { LoadAction::Clear };
                            pass.stencil_attachment.store_action = StoreAction::Store;
                            pass.stencil_attachment.clear_stencil = sclear;
                        }
                    }
                    if vis_id != 0 && vis_mode != 0 {
                        pass.visibility_result_buffer = Some(bufs.get(&vis_id).ok_or("no such visibility buffer")?.clone());
                    }
                    let cb = queue.command_buffer()?;
                    let mut enc = cb.render_command_encoder(&pass)?;
                    enc.set_render_pipeline_state(st)?;
                    if vis_id != 0 && vis_mode != 0 {
                        enc.set_visibility_result_mode(if vis_mode == 2 { VisibilityResultMode::Counting } else { VisibilityResultMode::Boolean }, vis_off)?;
                    }
                    if ds_id != 0 {
                        enc.set_depth_stencil_state(dss.get(&ds_id).ok_or("no such depth stencil state")?)?;
                    }
                    if has_st {
                        enc.set_stencil_reference_values(sref_f, sref_b);
                    }
                    enc.set_cull_mode(CullMode::try_from(cull)?);
                    enc.set_front_facing_winding(Winding::try_from(wind)?);
                    for k in 0..nvb {
                        let o = 88 + k * 12;
                        let b = bufs.get(&u32at(&p, o)).ok_or("no such buffer")?;
                        enc.set_vertex_buffer(Some(b), u32at(&p, o + 8) as u64, u32at(&p, o + 4))?;
                    }
                    for k in 0..nft {
                        let o = 88 + nvb * 12 + k * 8;
                        let (t, _, _) = texs.get(&u32at(&p, o)).ok_or("no such fragment texture")?;
                        enc.set_fragment_texture(Some(t), u32at(&p, o + 4))?;
                    }
                    for k in 0..nfb {
                        let o = 88 + nvb * 12 + nft * 8 + k * 12;
                        let b = bufs.get(&u32at(&p, o)).ok_or("no such fragment buffer")?;
                        enc.set_fragment_buffer(Some(b), u32at(&p, o + 8) as u64, u32at(&p, o + 4))?;
                    }
                    let so = 88 + nvb * 12 + nft * 8 + nfb * 12;
                    if p.len() >= so + 4 {
                        let nfs = u32at(&p, so) as usize;
                        for k in 0..nfs {
                            let o = so + 4 + k * 8;
                            let sm = samplers.get(&u32at(&p, o)).ok_or("no such sampler")?;
                            enc.set_fragment_sampler_state(Some(sm), u32at(&p, o + 4))?;
                        }
                    }
                    {
                        let so = 88 + nvb * 12 + nft * 8 + nfb * 12;
                        let nfs = if p.len() >= so + 4 { u32at(&p, so) as usize } else { 0 };
                        let vo = so + 4 + nfs * 8;
                        if p.len() >= vo + 48 {
                            let fv = |i: usize| f32::from_bits(u32at(&p, vo + 4 + i * 4)) as f64;
                            if u32at(&p, vo) != 0 {
                                let mut vp = Viewport::default();
                                vp.origin_x = fv(0);
                                vp.origin_y = fv(1);
                                vp.width = fv(2);
                                vp.height = fv(3);
                                vp.znear = fv(4);
                                vp.zfar = fv(5);
                                enc.set_viewport(vp)?;
                            }
                            if u32at(&p, vo + 28) != 0 {
                                let mut sc = ScissorRect::default();
                                sc.x = u32at(&p, vo + 32) as u64;
                                sc.y = u32at(&p, vo + 36) as u64;
                                sc.width = u32at(&p, vo + 40) as u64;
                                sc.height = u32at(&p, vo + 44) as u64;
                                enc.set_scissor_rect(sc)?;
                            }
                            let mut o = vo + 48;
                            if p.len() >= o + 4 {
                                let nvt = u32at(&p, o) as usize;
                                o += 4;
                                for k in 0..nvt {
                                    let (t, _, _) = texs.get(&u32at(&p, o + k * 8)).ok_or("no such vertex texture")?;
                                    enc.set_vertex_texture(Some(t), u32at(&p, o + k * 8 + 4))?;
                                }
                                o += nvt * 8;
                            }
                            if p.len() >= o + 4 {
                                let nvs = u32at(&p, o) as usize;
                                o += 4;
                                for k in 0..nvs {
                                    let sm = samplers.get(&u32at(&p, o + k * 8)).ok_or("no such vertex sampler")?;
                                    enc.set_vertex_sampler_state(Some(sm), u32at(&p, o + k * 8 + 4))?;
                                }
                            }
                        }
                    }
                    let pt = match prim {
                        0 => PrimitiveType::Point,
                        1 => PrimitiveType::Line,
                        2 => PrimitiveType::LineStrip,
                        4 => PrimitiveType::TriangleStrip,
                        _ => PrimitiveType::Triangle,
                    };
                    if idxbuf != 0 {
                        let ib = bufs.get(&idxbuf).ok_or("no such index buffer")?;
                        let it = if idxtype == 1 { IndexType::UInt32 } else { IndexType::UInt16 };
                        enc.draw_indexed_primitives(pt, count, it, ib, idxoff, ninst, bvert, binst)?;
                    } else {
                        enc.draw_primitives(pt, start as u32, count, ninst, binst)?;
                    }
                    enc.end_encoding()?;
                    cb.commit()?;
                    cb.wait_until_completed_for(Duration::from_secs(20)).map_err(|_| "gpu timeout")?;
                }
                13 => {
                    // TEX_REGION: texture, x, y, w, h, then w*h*4 bytes of RGBA8
                    let (tex, tw, th) = texs.get(&u32at(&p, 0)).ok_or("no such texture")?;
                    let (x, y, w, h) = (u32at(&p, 4) as u64, u32at(&p, 8) as u64, u32at(&p, 12) as u64, u32at(&p, 16) as u64);
                    let level = u32at(&p, 20) as u64;
                    let (wslice, wz) = (u32at(&p, 24) as u64, u32at(&p, 28) as u64);
                    let kind = ttypes.get(&u32at(&p, 0)).copied().unwrap_or(2);
                    let (wslice, wz) = if kind == 7 { (0, wz) } else { (wslice, 0) };
                    let (tw, th) = ((*tw >> level).max(1), (*th >> level).max(1));
                    let need = (w * h * 4) as usize;
                    if x + w > tw || y + h > th || p.len() < 32 + need {
                        return Err("texture region does not fit".into());
                    }
                    let sb = device.new_buffer_with_bytes(&p[32..32 + need], ResourceOptions::shared())?;
                    let cb = queue.command_buffer()?;
                    let mut blit = cb.blit_command_encoder()?;
                    blit.copy_from_buffer_to_texture(&sb, 0, w * 4, w * 4 * h, Size::new(w, h, 1), tex, wslice, level, Origin::new(x, y, wz), BlitOption::None)?;
                    blit.end_encoding()?;
                    cb.commit()?;
                    cb.wait_until_completed_for(Duration::from_secs(20)).map_err(|_| "gpu timeout")?;
                }
                14 => {
                    // FREE: kind (1 buffer, 2 texture, 3 library, 4 compute pipeline, 5 render pipeline), id
                    let id = u32at(&p, 4);
                    match u32at(&p, 0) {
                        1 => {
                            bufs.remove(&id);
                        }
                        2 => {
                            ttypes.remove(&id);
                            texs.remove(&id);
                        }
                        3 => {
                            libs.remove(&id);
                        }
                        4 => {
                            psos.remove(&id);
                        }
                        5 => {
                            rpsos.remove(&id);
                        }
                        6 => {
                            dss.remove(&id);
                        }
                        7 => {
                            samplers.remove(&id);
                        }
                        _ => {}
                    }
                }
                15 => {
                    // NEW_RENDER_EX: library, blend[8], vertex-name length, vertex name, fragment name
                    let lib = libs.get(&u32at(&p, 0)).ok_or("no such library")?;
                    let vl = u32at(&p, 44) as usize;
                    let vname = std::str::from_utf8(&p[48..48 + vl])?;
                    let fname = std::str::from_utf8(&p[48 + vl..])?;
                    let vf = lib.new_function_with_name(vname)?;
                    let ff = lib.new_function_with_name(fname)?;
                    let mut d = RenderPipelineDescriptor::new(StageSource::Function(vf.function_descriptor()));
                    d.fragment = Some(StageSource::Function(ff.function_descriptor()));
                    let mut ca = ColorAttachmentDescriptor::new(PixelFormat::RGBA8Unorm);
                    ca.blending_enabled = u32at(&p, 4) != 0;
                    ca.source_rgb_blend_factor = BlendFactor::try_from(u32at(&p, 8))?;
                    ca.destination_rgb_blend_factor = BlendFactor::try_from(u32at(&p, 12))?;
                    ca.rgb_blend_operation = BlendOperation::try_from(u32at(&p, 16))?;
                    ca.source_alpha_blend_factor = BlendFactor::try_from(u32at(&p, 20))?;
                    ca.destination_alpha_blend_factor = BlendFactor::try_from(u32at(&p, 24))?;
                    ca.alpha_blend_operation = BlendOperation::try_from(u32at(&p, 28))?;
                    ca.write_mask = ColorWriteMask::try_from(u32at(&p, 32))?;
                    d.color_attachments[0] = Some(ca);
                    d.depth_format = match u32at(&p, 36) {
                        1 => Some(PixelFormat::Depth32Float),
                        2 => Some(PixelFormat::Depth32FloatStencil8),
                        _ => None,
                    };
                    d.raster_sample_count = u32at(&p, 40).max(1);
                    d.stencil_format = if u32at(&p, 36) == 2 { Some(PixelFormat::Depth32FloatStencil8) } else { None };
                    rpsos.insert(next, device.new_render_pipeline_state(&d, &PipelineOptions::default())?);
                    result = next;
                    next += 1;
                }
                16 => {
                    // NEW_DEPTH_STENCIL: compare function, depth write
                    let mut d = DepthStencilDescriptor::default();
                    d.depth_compare_function = CompareFunction::try_from(u32at(&p, 0))?;
                    d.depth_write_enabled = u32at(&p, 4) != 0;
                    if p.len() >= 56 {
                        let face = |o: usize| -> Result<StencilDescriptor, Box<dyn std::error::Error>> {
                            let mut f = StencilDescriptor::default();
                            f.stencil_compare_function = CompareFunction::try_from(u32at(&p, o))?;
                            f.stencil_failure_operation = StencilOperation::try_from(u32at(&p, o + 4))?;
                            f.depth_failure_operation = StencilOperation::try_from(u32at(&p, o + 8))?;
                            f.depth_stencil_pass_operation = StencilOperation::try_from(u32at(&p, o + 12))?;
                            f.read_mask = u32at(&p, o + 16);
                            f.write_mask = u32at(&p, o + 20);
                            Ok(f)
                        };
                        d.front_face_stencil = face(8)?;
                        d.back_face_stencil = face(32)?;
                    }
                    dss.insert(next, device.new_depth_stencil_state(&d)?);
                    result = next;
                    next += 1;
                }
                17 => {
                    // NEW_SAMPLER
                    let mut d = SamplerDescriptor::new();
                    d.min_filter = SamplerMinMagFilter::try_from(u32at(&p, 0))?;
                    d.mag_filter = SamplerMinMagFilter::try_from(u32at(&p, 4))?;
                    d.mip_filter = SamplerMipFilter::try_from(u32at(&p, 8))?;
                    d.s_address_mode = SamplerAddressMode::try_from(u32at(&p, 12))?;
                    d.t_address_mode = SamplerAddressMode::try_from(u32at(&p, 16))?;
                    d.r_address_mode = SamplerAddressMode::try_from(u32at(&p, 20))?;
                    d.border_color = SamplerBorderColor::try_from(u32at(&p, 24))?;
                    d.normalized_coordinates = u32at(&p, 28) != 0;
                    d.lod_min_clamp = f32::from_bits(u32at(&p, 32));
                    d.lod_max_clamp = f32::from_bits(u32at(&p, 36));
                    d.max_anisotropy = u32at(&p, 40).max(1);
                    d.compare_function = CompareFunction::try_from(u32at(&p, 44))?;
                    samplers.insert(next, device.new_sampler_state(&d)?);
                    result = next;
                    next += 1;
                }
                18 => {
                    // GEN_MIPS: texture id
                    let (tex, _, _) = texs.get(&u32at(&p, 0)).ok_or("no such texture")?;
                    let cb = queue.command_buffer()?;
                    let mut blit = cb.blit_command_encoder()?;
                    blit.generate_mipmaps(tex)?;
                    blit.end_encoding()?;
                    cb.commit()?;
                    cb.wait_until_completed_for(Duration::from_secs(20)).map_err(|_| "gpu timeout")?;
                }
                _ => return Err("unknown op".into()),
            }
            Ok(())
        })();
        if let Err(e) = out {
            eprintln!("op {op}: {e}");
            status = 1;
        }
        if !resp.is_empty() {
            ring.write_bytes(PAYLOAD_OFF, &resp);
        }
        w(6, resp.len() as u32);
        w(5, result);
        w(7, extra);
        w(3, status);
        last = req;
        w(2, req);
    }
}
