//! Stand-in for the iOS side: fills the ring with a triangle, waits, reports latency, dumps a PPM.
#[path = "../ring.rs"]
mod ring;
use ring::*;
use std::time::{Duration, Instant};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let w: u32 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(540);
    let h: u32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1212);
    let frames: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(60);
    let r = Ring::open(false);
    assert_eq!(r.load(MAGIC_W), MAGIC, "server not running");
    r.store(WIDTH, w);
    r.store(HEIGHT, h);
    r.store(CLEAR, 0xff1a0d0d);
    let t0 = Instant::now();
    for f in 0..frames {
        let a = f as f32 * 0.05;
        let (s, c) = a.sin_cos();
        let tri = [(0.0f32, -0.6f32, 1.0f32, 0.0f32, 0.0f32), (0.6, 0.6, 0.0, 1.0, 0.0), (-0.6, 0.6, 0.0, 0.0, 1.0)];
        let mut vb = Vec::new();
        for (x, y, cr, cg, cb) in tri.iter() {
            let (rx, ry) = (x * c - y * s, x * s + y * c);
            let d = [rx, ry * (w as f32 / h as f32), *cr, *cg, *cb, 1.0];
            for val in d.iter() {
                vb.extend_from_slice(&val.to_le_bytes());
            }
        }
        r.write_bytes(VERT_OFF, &vb);
        r.store(NVERTS, 3);
        let seq = r.load(REQ) + 1;
        r.store(REQ, seq);
        let t = Instant::now();
        while r.load(DONE) != seq {
            if t.elapsed() > Duration::from_secs(10) {
                println!("timeout");
                return;
            }
            std::hint::spin_loop();
        }
    }
    let el = t0.elapsed().as_secs_f64();
    println!("{frames} frames {w}x{h} in {el:.3}s = {:.1} fps, last server time {} us", frames as f64 / el, r.load(GPU_US));
    let mut px = vec![0u8; (w * h * 4) as usize];
    r.read_bytes(PIX_OFF, &mut px);
    let mut out = format!("P6\n{w} {h}\n255\n").into_bytes();
    for p in px.chunks(4) {
        out.extend_from_slice(&p[..3]);
    }
    std::fs::write("/data/local/tmp/ring_frame.ppm", out).unwrap();
}
