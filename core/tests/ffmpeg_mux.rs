//! `ffmpeg` mux'unun gercek medya dosyalariyla calistigini gosterir.
//!
//! `ffmpeg` PATH'te yoksa ya da test medyasi uretemezse test atlanir: mux
//! opsiyoneldir ve motor onsuz da calisir (video ana dosya, ses ayri kalir).

use std::path::{Path, PathBuf};
use std::process::Command;

use serene_core::ffmpeg;

/// Gecici klasor agac icinde tutulur: bazi ortamlarda `%TEMP%` yazimi engelli.
fn workspace() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target")
        .join("ffmpeg-mux-test");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("gecici klasor olusturulamadi");
    dir
}

fn make_media(out: &Path, args: &[&str]) -> bool {
    Command::new("ffmpeg")
        .args(["-y", "-loglevel", "error"])
        .args(args)
        .arg(out)
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

#[tokio::test]
async fn mux_combines_video_and_audio_into_one_file() {
    if !ffmpeg::available() {
        eprintln!("ffmpeg PATH'te yok; mux testi atlandi");
        return;
    }

    let dir = workspace();
    let video = dir.join("v.mp4");
    let audio = dir.join("a.m4a");
    let out = dir.join("out.mp4");

    let v_ok = make_media(
        &video,
        &[
            "-f",
            "lavfi",
            "-i",
            "testsrc=duration=1:size=128x72:rate=10",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
        ],
    );
    let a_ok = make_media(
        &audio,
        &[
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=1",
            "-c:a",
            "aac",
        ],
    );
    if !v_ok || !a_ok {
        eprintln!("ffmpeg test medyasi uretemedi (encoder eksik olabilir); atlandi");
        return;
    }

    ffmpeg::mux(&video, &audio, &out)
        .await
        .expect("mux basarisiz oldu");
    let size = std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0);
    assert!(size > 0, "mux ciktisi bos");

    let _ = std::fs::remove_dir_all(&dir);
}
