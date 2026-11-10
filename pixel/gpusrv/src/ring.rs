//! Ring between a client (the iOS side later) and the GPU server, over pread/pwrite so that the
//! backing can be a plain file or /dev/cubs_ram (the reserved span shared with XNU).
//! Layout from RING_BASE: 16 u32 header words, vertex data at 64, pixels at PIX_OFF.
//! Env: RING_DEV (default /data/local/tmp/gpu_ring.bin), RING_BASE (hex offset, default 0).
use std::ffi::CString;

pub const MAGIC: u32 = 0x4750_5531; // "GPU1"
pub const MAX_VERTS: usize = 3072;
pub const VERT_OFF: usize = 64;
pub const PIX_OFF: usize = 65536;
pub const MAX_W: usize = 1080;
pub const MAX_H: usize = 2424;
pub const SIZE: usize = PIX_OFF + MAX_W * MAX_H * 4;
// header word indexes
pub const MAGIC_W: usize = 0;
pub const REQ: usize = 1;
pub const DONE: usize = 2;
pub const WIDTH: usize = 3;
pub const HEIGHT: usize = 4;
pub const NVERTS: usize = 5;
pub const CLEAR: usize = 6; // packed RGBA8
pub const GPU_US: usize = 7;

pub struct Ring {
    fd: i32,
    base: i64,
}

impl Ring {
    pub fn open(create: bool) -> Ring {
        let path = std::env::var("RING_DEV").unwrap_or("/data/local/tmp/gpu_ring.bin".into());
        let base = std::env::var("RING_BASE").ok().and_then(|s| i64::from_str_radix(&s, 16).ok()).unwrap_or(0);
        let p = CString::new(path).unwrap();
        unsafe {
            let fd = libc::open(p.as_ptr(), libc::O_RDWR | if create { libc::O_CREAT } else { 0 }, 0o666);
            assert!(fd >= 0, "open ring");
            if create {
                let mut st: libc::stat = std::mem::zeroed();
                libc::fstat(fd, &mut st);
                if (st.st_mode & libc::S_IFMT) == libc::S_IFREG {
                    libc::ftruncate(fd, (base as usize + SIZE) as i64);
                }
            }
            Ring { fd, base }
        }
    }
    pub fn read_bytes(&self, off: usize, out: &mut [u8]) {
        let mut done = 0;
        while done < out.len() {
            let n = unsafe { libc::pread(self.fd, out[done..].as_mut_ptr() as *mut _, out.len() - done, self.base + (off + done) as i64) };
            assert!(n > 0, "ring read failed");
            done += n as usize;
        }
    }
    pub fn write_bytes(&self, off: usize, data: &[u8]) {
        let mut done = 0;
        while done < data.len() {
            let n = unsafe { libc::pwrite(self.fd, data[done..].as_ptr() as *const _, data.len() - done, self.base + (off + done) as i64) };
            assert!(n > 0, "ring write failed");
            done += n as usize;
        }
    }
    pub fn load(&self, i: usize) -> u32 {
        let mut b = [0u8; 4];
        self.read_bytes(i * 4, &mut b);
        u32::from_le_bytes(b)
    }
    pub fn store(&self, i: usize, v: u32) {
        self.write_bytes(i * 4, &v.to_le_bytes());
    }
}
