//! Motorun kendi async calisma zamani.
//!
//! Kabuk hangi iplikten cagirirsa cagsin (Tauri `setup` ana iplikte kosar,
//! Flutter'da FFI cagrisi kendi ipliğinden gelir) arka plan gorevleri daima
//! burada kosar; boylece "runtime baglami yok" panigi hicbir kabukta olusmaz.

use std::sync::OnceLock;

use tokio::runtime::{Builder, Runtime};

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("tokio calisma zamani kurulamadi")
    })
}

/// Arka plan gorevlerini buradan tasin; `tokio::spawn` cagirisinin aksine
/// cagiran iplikten bagimsizdir.
pub fn spawn<T>(task: T) -> tokio::task::JoinHandle<T::Output>
where
    T: std::future::Future + Send + 'static,
    T::Output: Send + 'static,
{
    runtime().spawn(task)
}
