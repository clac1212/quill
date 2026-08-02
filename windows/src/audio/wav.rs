//! Crash-tolerant WAV writer (plan decision 3).
//!
//! Checkpoint order: sync appended PCM, persist the RIFF length, then persist
//! the `data` length. A kill between header writes exposes the previous data
//! checkpoint, so declared audio never runs ahead of durable PCM.

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
    finished: bool,
    #[cfg(test)]
    crash_stage: Option<CrashStage>,
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
        file.sync_data()?;
        Ok(Self {
            file,
            data_bytes: 0,
            frames: 0,
            peak: 0.0,
            patch_interval,
            last_patch: Instant::now(),
            finished: false,
            #[cfg(test)]
            crash_stage: None,
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
            self.checkpoint()?;
            self.last_patch = Instant::now();
        }
        Ok(())
    }

    /// Durably declare everything appended so far. RIFF length is persisted
    /// before data length so an interrupted checkpoint exposes only the prior
    /// complete data checkpoint.
    fn checkpoint(&mut self) -> std::io::Result<()> {
        let riff_size = u32::try_from(HEADER_LEN - 8 + self.data_bytes).map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "WAV exceeds 4 GiB")
        })?;
        let data_size = u32::try_from(self.data_bytes).map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "WAV exceeds 4 GiB")
        })?;

        self.file.sync_data()?;
        self.abort_if_requested(CrashStage::Pcm);
        self.file.seek(SeekFrom::Start(RIFF_SIZE_OFFSET))?;
        self.file.write_all(&riff_size.to_le_bytes())?;
        self.file.sync_data()?;
        self.abort_if_requested(CrashStage::RiffLength);
        self.file.seek(SeekFrom::Start(DATA_SIZE_OFFSET))?;
        self.file.write_all(&data_size.to_le_bytes())?;
        self.file.sync_data()?;
        self.abort_if_requested(CrashStage::DataLength);
        self.file.seek(SeekFrom::End(0))?;
        Ok(())
    }

    pub fn finish(mut self) -> std::io::Result<TrackStats> {
        self.checkpoint()?;
        self.finished = true;
        Ok(TrackStats {
            frames_written: self.frames,
            peak_amplitude: self.peak,
        })
    }

    #[cfg(test)]
    fn abort_if_requested(&self, stage: CrashStage) {
        if self.crash_stage == Some(stage) {
            std::process::abort();
        }
    }

    #[cfg(not(test))]
    fn abort_if_requested(&self, _stage: CrashStage) {}
}

impl Drop for WavWriter {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.checkpoint();
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CrashStage {
    Pcm,
    RiffLength,
    DataLength,
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
    //! Truncation harness: an ignored helper test is launched in a subprocess
    //! and aborts at each durability boundary. The parent then opens the
    //! checkpoint with a real WAV decoder.

    use super::*;
    use std::io::Read;
    use std::process::Command;

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
        assert!(p.declared_riff >= 36 + p.declared_data);
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
    fn kill_after_patch() {
        let path = tmp("post-patch.wav");
        let mut w = WavWriter::with_patch_interval(&path, 48_000, Duration::ZERO).unwrap();
        w.write_samples(&[1000i16; 4800]).unwrap();

        let bytes = snapshot(&path);
        assert_invariant(&bytes);
        assert_eq!(parse(&bytes).declared_data, 4800 * 2);
        drop(w);
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

    #[test]
    fn aborted_checkpoint_remains_decodable_at_every_boundary() {
        for (stage, expected_samples) in [
            ("data-synced", 480usize),
            ("riff-synced", 480),
            ("data-size-synced", 960),
        ] {
            let path = tmp(&format!("abort-{stage}.wav"));
            let status = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "audio::wav::tests::checkpoint_abort_helper",
                    "--ignored",
                ])
                .env("QUILL_WAV_CRASH_STAGE", stage)
                .env("QUILL_WAV_CRASH_PATH", &path)
                .status()
                .unwrap();
            assert!(!status.success(), "helper did not abort at {stage}");

            let bytes = snapshot(&path);
            assert_invariant(&bytes);
            let mut reader = hound::WavReader::open(&path).unwrap();
            assert_eq!(reader.spec().sample_rate, 48_000);
            let samples: Result<Vec<i16>, _> = reader.samples::<i16>().collect();
            assert_eq!(samples.unwrap().len(), expected_samples);
        }
    }

    #[test]
    #[ignore = "subprocess helper for aborted_checkpoint_remains_decodable_at_every_boundary"]
    fn checkpoint_abort_helper() {
        let stage = match std::env::var("QUILL_WAV_CRASH_STAGE").unwrap().as_str() {
            "data-synced" => CrashStage::Pcm,
            "riff-synced" => CrashStage::RiffLength,
            "data-size-synced" => CrashStage::DataLength,
            other => panic!("unknown crash stage: {other}"),
        };
        let path = std::path::PathBuf::from(std::env::var_os("QUILL_WAV_CRASH_PATH").unwrap());
        let mut writer = WavWriter::with_patch_interval(&path, 48_000, Duration::ZERO).unwrap();
        writer.write_samples(&[1000i16; 480]).unwrap();
        writer.crash_stage = Some(stage);
        writer.write_samples(&[-2000i16; 480]).unwrap();
        panic!("checkpoint did not abort");
    }
}
