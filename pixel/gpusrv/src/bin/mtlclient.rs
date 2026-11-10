//! Linux-side test client of the Metal RPC (mtlsrv): the compute_dispatch example of metal2vulkan, driven through the ring.
//! usage: mtlclient [fixture.bc]   (env RING_DEV / RING_BASE as for the other tools)
#[path = "../ring.rs"]
mod ring;
use ring::*;
use std::time::{Duration, Instant};

const RPC_OFF: usize = 0xB0_0000;
const PAYLOAD_OFF: usize = RPC_OFF + 0x1000;

struct Rpc {
    r: Ring,
    seq: u32,
}

impl Rpc {
    fn word(&self, i: usize) -> u32 {
        let mut b = [0u8; 4];
        self.r.read_bytes(RPC_OFF + i * 4, &mut b);
        u32::from_le_bytes(b)
    }
    fn call(&mut self, op: u32, payload: &[u8]) -> (u32, u32, Vec<u8>) {
        self.r.write_bytes(PAYLOAD_OFF, payload);
        self.r.write_bytes(RPC_OFF + 4 * 4, &op.to_le_bytes());
        self.r.write_bytes(RPC_OFF + 6 * 4, &(payload.len() as u32).to_le_bytes());
        self.seq += 1;
        self.r.write_bytes(RPC_OFF + 4, &self.seq.to_le_bytes());
        let t = Instant::now();
        while self.word(2) != self.seq {
            assert!(t.elapsed() < Duration::from_secs(30), "server did not answer");
            std::thread::sleep(Duration::from_micros(300));
        }
        let (status, result, rl) = (self.word(3), self.word(5), self.word(6) as usize);
        let mut resp = vec![0u8; rl];
        if rl > 0 {
            self.r.read_bytes(PAYLOAD_OFF, &mut resp);
        }
        (status, result, resp)
    }
}

fn u(v: u32) -> [u8; 4] {
    v.to_le_bytes()
}

fn main() {
    let bc = std::fs::read(std::env::args().nth(1).unwrap_or("/data/local/tmp/fixture.bc".into())).unwrap();
    let mut c = Rpc { r: Ring::open(false), seq: 0 };
    assert_eq!(c.word(0), 0x4d54_4c31, "no Metal RPC server");
    c.seq = c.word(1);
    let (s, lib, _) = c.call(1, &bc);
    assert_eq!(s, 0, "new library");
    let mut name = u(lib).to_vec();
    name.extend_from_slice(b"scale_and_offset");
    let (s, pso, _) = c.call(5, &name);
    assert_eq!(s, 0, "new pipeline");
    println!("library {lib}, pipeline {pso}, max threads {}", c.word(7));
    const N: usize = 1000;
    let input: Vec<u8> = (0..N).flat_map(|i| (i as f32).to_le_bytes()).collect();
    let mk = |c: &mut Rpc, len: usize, init: Option<&[u8]>| {
        let mut p = u(len as u32).to_vec();
        p.extend_from_slice(&u(init.is_some() as u32));
        if let Some(d) = init {
            p.extend_from_slice(d);
        }
        let (s, id, _) = c.call(2, &p);
        assert_eq!(s, 0, "new buffer");
        id
    };
    let bin = mk(&mut c, N * 4, Some(&input));
    let bout = mk(&mut c, N * 4, None);
    let bscale = mk(&mut c, 4, Some(&2.0f32.to_le_bytes()));
    let mut d = Vec::new();
    for v in [pso, 3, N as u32, 1, 1, 64, 1, 1, bin, 0, 0, bout, 1, 0, bscale, 2, 0] {
        d.extend_from_slice(&u(v));
    }
    let t = Instant::now();
    let (s, _, _) = c.call(6, &d);
    assert_eq!(s, 0, "dispatch");
    let (s, _, out) = c.call(4, &[u(bout), u(0), u((N * 4) as u32)].concat());
    assert_eq!(s, 0, "read");
    println!("dispatch + read back: {:?}", t.elapsed());
    for i in 0..N {
        let v = f32::from_le_bytes([out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3]]);
        assert_eq!(v, 3.0 * i as f32, "output[{i}]");
    }
    println!("compute over the ring: output[999] = {}: as expected", f32::from_le_bytes([out[3996], out[3997], out[3998], out[3999]]));

    // render_to_texture of the metal2vulkan examples, through the ring: 8x8 target cleared blue, two triangles over the top-left quarter
    let (s, tex, _) = c.call(7, &[u(8), u(8)].concat());
    assert_eq!(s, 0, "new texture");
    let mut rp = u(lib).to_vec();
    rp.extend_from_slice(&u(14));
    rp.extend_from_slice(b"colored_vertex");
    rp.extend_from_slice(b"colored_fragment");
    let (s, rpso, _) = c.call(8, &rp);
    assert_eq!(s, 0, "new render pipeline");
    let pos: [f32; 12] = [-1.0, 1.0, 0.0, 1.0, -1.0, 0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 0.0];
    let posb: Vec<u8> = pos.iter().flat_map(|v| v.to_le_bytes()).collect();
    let colb: Vec<u8> = (0..6).flat_map(|_| [1.0f32, 0.2, 0.0, 1.0]).flat_map(|v| v.to_le_bytes()).collect();
    let bpos = mk(&mut c, posb.len(), Some(&posb));
    let bcol = mk(&mut c, colb.len(), Some(&colb));
    let mut d = Vec::new();
    for v in [rpso, tex, 0.0f32.to_bits(), 0.0f32.to_bits(), 1.0f32.to_bits(), 1.0f32.to_bits(), 2, 3, 0, 6, bpos, 0, 0, bcol, 1, 0] {
        d.extend_from_slice(&u(v));
    }
    let t = Instant::now();
    let (s, _, _) = c.call(9, &d);
    assert_eq!(s, 0, "render");
    let (s, _, px) = c.call(10, &u(tex));
    assert_eq!(s, 0, "read texture");
    println!("render + read back: {:?}", t.elapsed());
    for y in 0..8usize {
        for x in 0..8usize {
            let at = (y * 8 + x) * 4;
            let inside = x < 4 && y < 4;
            let want: [u8; 4] = if inside { [255, 51, 0, 255] } else { [0, 0, 255, 255] };
            assert_eq!(&px[at..at + 4], &want, "texel ({x},{y})");
        }
    }
    println!("render over the ring: every texel as expected");
}
