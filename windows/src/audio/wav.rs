//! Crash-tolerant WAV writer (plan decision 3).
//!
//! Write order per patch interval: append PCM, then rewrite the RIFF and
//! `data` chunk sizes to cover exactly the bytes already written — so the
//! declared length never runs ahead of durable data. A kill at any point
//! loses at most one interval of *declared* audio; samples past the declared
//! length survive on disk and tools that read to EOF (ffmpeg) recover them.

use std::fs::File;
use std::io::{Seek, SeekFrom, Write};
use std::path::Path;
use std::time::{Duration, Instant};

use crate::audio::TrackStats;

const HEADER_LEN: u64 = 44;
const RIFF_SIZE_OFFSET: u64 = 4;
const DATA_SIZE_OFFSET: u64 = 40;
pub const PATCH_INTERVAL: Duration = Duration::from_secs(10);

/// 16-bit PCM mono writer. Unbuffered: every `write_samples` call reaches
/// the OS immediately, so durability is bounded by the patch interval alone.
pub struct WavWriter {
    file: File,
    data_bytes: u64,
    frames: u64,
    peak: f32,
    patch_interval: Duration,
    last_patch: Instant,
}

impl WavWriter {
    pub fn create(path: &Path, sample_rate: u32) -> std::io::Result<Self> {
        Self::with_patch_interval(path, sample_rate, PATCH_INTERVAL)
    }

    pub fn with_patch_interval(
        path: &Path,
        sample_rate: u32,
        patch_interval: Duration,
    ) -> std::io::Result<Self> {
        let mut file = File::create(path)?;
        file.write_all(&header(sample_rate, 0))?;
        Ok(Self {
            file,
            data_bytes: 0,
            frames: 0,
            peak: 0.0,
            patch_interval,
            last_patch: Instant::now(),
        })
    }

    pub fn write_samples(&mut self, mono: &[i16]) -> std::io::Result<()> {
        let mut bytes = Vec::with_capacity(mono.len() * 2);
        for &s in mono {
            bytes.extend_from_slice(&s.to_le_bytes());
            let amp = (s as f32 / 32768.0).abs();
            if amp > self.peak {
                self.peak = amp;
            }
        }
        self.file.write_all(&bytes)?;
        self.data_bytes += bytes.len() as u64;
        self.frames += mono.len() as u64;

        if self.last_patch.elapsed() >= self.patch_interval {
            self.patch_header()?;
            self.last_patch = Instant::now();
        }
        Ok(())
    }

    /// Declare everything appended so far. Data first, sizes second: by the
    /// time a size is on disk, the bytes it covers already are.
    fn patch_header(&mut self) -> std::io::Result<()> {
        let riff_size = (HEADER_LEN - 8 + self.data_bytes) as u32;
        let data_size = self.data_bytes as u32;
        self.file.seek(SeekFrom::Start(RIFF_SIZE_OFFSET))?;
        self.file.write_all(&riff_size.to_le_bytes())?;
        self.file.seek(SeekFrom::Start(DATA_SIZE_OFFSET))?;
        self.file.write_all(&data_size.to_le_bytes())?;
        self.file.seek(SeekFrom::End(0))?;
        Ok(())
    }

    pub fn finish(mut self) -> std::io::Result<TrackStats> {
        self.patch_header()?;
        self.file.sync_data()?;
        Ok(TrackStats {
            frames_written: self.frames,
            peak_amplitude: self.peak,
        })
    }
}

fn header(sample_rate: u32, data_bytes: u32) -> [u8; HEADER_LEN as usize] {
    let byte_rate = sample_rate * 2;
    let mut h = [0u8; HEADER_LEN as usize];
    h[0..4].copy_from_slice(b"RIFF");
    h[4..8].copy_from_slice(&(36 + data_bytes).to_le_bytes());
    h[8..12].copy_from_slice(b"WAVE");
    h[12..16].copy_from_slice(b"fmt ");
    h[16..20].copy_from_slice(&16u32.to_le_bytes());
    h[20..22].copy_from_slice(&1u16.to_le_bytes()); // PCM
    h[22..24].copy_from_slice(&1u16.to_le_bytes()); // mono
    h[24..28].copy_from_slice(&sample_rate.to_le_bytes());
    h[28..32].copy_from_slice(&byte_rate.to_le_bytes());
    h[32..34].copy_from_slice(&2u16.to_le_bytes()); // block align
    h[34..36].copy_from_slice(&16u16.to_le_bytes()); // bits per sample
    h[36..40].copy_from_slice(b"data");
    h[40..44].copy_from_slice(&data_bytes.to_le_bytes());
    h
}

#[cfg(test)]
mod tests {
    //! Truncation harness: a kill is simulated by snapshotting the file
    //! bytes at each point in the append → patch cycle — writes are visible
    //! to other readers the moment `write_all` returns, so the on-disk state
    //! mid-cycle *is* the state a kill would leave.

    use super::*;
    use std::io::Read;

    struct Parsed {
        declared_data: u32,
        declared_riff: u32,
        durable_data: u64,
    }

    fn parse(bytes: &[u8]) -> Parsed {
        assert!(bytes.len() >= HEADER_LEN as usize, "header incomplete");
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(&bytes[36..40], b"data");
        Parsed {
            declared_riff: u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
            declared_data: u32::from_le_bytes(bytes[40..44].try_into().unwrap()),
            durable_data: bytes.len() as u64 - HEADER_LEN,
        }
    }

    fn assert_invariant(bytes: &[u8]) {
        let p = parse(bytes);
        assert!(
            (p.declared_data as u64) <= p.durable_data,
            "declared {} > durable {}",
            p.declared_data,
            p.durable_data
        );
        assert_eq!(p.declared_riff, 36 + p.declared_data);
    }

    fn snapshot(path: &Path) -> Vec<u8> {
        let mut buf = Vec::new();
        File::open(path).unwrap().read_to_end(&mut buf).unwrap();
        buf
    }

    fn tmp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join("quill-wav-tests");
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(name)
    }

    #[test]
    fn kill_after_create() {
        let path = tmp("create.wav");
        let _w = WavWriter::create(&path, 48_000).unwrap();
        assert_invariant(&snapshot(&path));
    }

    #[test]
    fn kill_between_append_and_patch() {
        let path = tmp("mid-cycle.wav");
        // Interval an hour out: appends land, no patch ever runs.
        let mut w =
            WavWriter::with_patch_interval(&path, 48_000, Duration::from_secs(3600)).unwrap();
        w.write_samples(&[1000i16; 4800]).unwrap();
        w.write_samples(&[-2000i16; 4800]).unwrap();

        let bytes = snapshot(&path);
        assert_invariant(&bytes);
        let p = parse(&bytes);
        // Undeclared but durable: recoverable by EOF-reading tools.
        assert_eq!(p.declared_data, 0);
        assert_eq!(p.durable_data, 2 * 4800 * 2);
        std::mem::forget(w); // the simulated kill: no drop, no finish
    }

    #[test]
    fn kill_after_patch() {
        let path = tmp("post-patch.wav");
        let mut w = WavWriter::with_patch_interval(&path, 48_000, Duration::ZERO).unwrap();
        w.write_samples(&[1000i16; 4800]).unwrap();

        let bytes = snapshot(&path);
        assert_invariant(&bytes);
        assert_eq!(parse(&bytes).declared_data, 4800 * 2);
        std::mem::forget(w);
    }

    #[test]
    fn finish_declares_everything() {
        let path = tmp("finish.wav");
        let mut w =
            WavWriter::with_patch_interval(&path, 48_000, Duration::from_secs(3600)).unwrap();
        w.write_samples(&[i16::MIN; 4800]).unwrap();
        let stats = w.finish().unwrap();

        let bytes = snapshot(&path);
        assert_invariant(&bytes);
        let p = parse(&bytes);
        assert_eq!(p.declared_data as u64, p.durable_data);
        assert_eq!(stats.frames_written, 4800);
        assert!((stats.peak_amplitude - 1.0).abs() < 1e-6);
    }

    #[test]
    fn declared_length_is_monotonic_through_cycles() {
        let path = tmp("monotonic.wav");
        let mut w = WavWriter::with_patch_interval(&path, 48_000, Duration::ZERO).unwrap();
        let mut last_declared = 0u32;
        for _ in 0..5 {
            w.write_samples(&[500i16; 480]).unwrap();
            let p = parse(&snapshot(&path));
            assert_invariant(&snapshot(&path));
            assert!(p.declared_data >= last_declared);
            last_declared = p.declared_data;
        }
    }
}
