//! Serene'nin arayuzden bagimsiz indirme motoru.
//!
//! Kabuk (Tauri ya da Flutter) bu kutuphaneyi kurar, `EventBus`'a abone olur
//! ve komutlari cagrir. Motor ise hangi pencerenin cizildiğini bilmez.

pub mod bridge;
pub mod bus;
pub mod category;
pub mod clipboard;
pub mod dash;
pub mod engine;
pub mod enqueue;
pub mod hls;
pub mod manager;
pub mod models;
pub mod platform;
pub mod runtime;
pub mod store;
pub mod stream;

pub use bus::{CoreEvent, EventBus};
pub use manager::DownloadManager;
