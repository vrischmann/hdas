use tokio::sync::broadcast;

// Shutdown is a basic wrapper around a broadcast::Receiver.
//
// Mainly needed for passing the recv() future to with_graceful_shutdown().
pub struct Shutdown {
    shutdown_recv: broadcast::Receiver<()>,
}

impl Shutdown {
    pub fn new(shutdown_recv: broadcast::Receiver<()>) -> Self {
        Self { shutdown_recv }
    }

    pub async fn recv(&mut self) {
        let _ = self.shutdown_recv.recv().await;
    }
}
