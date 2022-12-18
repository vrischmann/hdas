use core::future::Future;
use secrecy::ExposeSecret;
use shutdown::Shutdown;
use std::net;
use std::str::FromStr;
use std::sync::Arc;
use tracing::{debug, error, info};

mod cleaner;
mod configuration;
mod db;
mod exporter;
mod health_data;
mod shutdown;
mod web;

async fn fallback_handler() -> (http::StatusCode, String) {
    (http::StatusCode::NOT_FOUND, "Page Not Found".to_owned())
}

struct App {
    connection_string: String,
    listen_addr: net::SocketAddr,
    victoria_addr: net::SocketAddr,
}

impl App {
    fn build(config: configuration::Config) -> anyhow::Result<Self> {
        let listen_addr = std::net::SocketAddr::from_str(&config.application.listen_addr)?;
        info!(listen_addr = listen_addr.to_string(), "got listen addr");

        let victoria_addr = std::net::SocketAddr::from_str(&config.application.victoria_addr)?;
        info!(
            victoria_addr = victoria_addr.to_string(),
            "got victoria addr"
        );

        Ok(Self {
            connection_string: config
                .database
                .connection_string()
                .expose_secret()
                .to_string(),
            listen_addr,
            victoria_addr,
        })
    }

    async fn run_web_app(
        db: Arc<db::Db>,
        listen_addr: net::SocketAddr,
        mut shutdown: Shutdown,
    ) -> anyhow::Result<()> {
        let state = web::State::new(db);

        // Build the router
        let web_app = axum::Router::new()
            .route("/health_data", axum::routing::post(web::health_data))
            .route("/metrics", axum::routing::get(web::metrics))
            .fallback(fallback_handler)
            .layer(tower_http::trace::TraceLayer::new_for_http())
            .with_state(state);

        let web_server = axum::Server::bind(&listen_addr)
            .serve(web_app.into_make_service())
            .with_graceful_shutdown(shutdown.recv());

        Ok(web_server.await?)
    }

    async fn run(self, shutdown: impl Future + std::marker::Send + 'static) -> anyhow::Result<()> {
        // Used for shutdown notinfications
        let (notify_shutdown_sender, _) = tokio::sync::broadcast::channel(2);

        // Initialize the database
        let db = Arc::new(db::Db::build(&self.connection_string).await?);

        // Start the exporter
        let exporter = exporter::Exporter::new(db.clone(), self.victoria_addr);
        let exporter_shutdown = Shutdown::new(notify_shutdown_sender.subscribe());
        let exporter = tokio::task::spawn(exporter.run(exporter_shutdown));

        // Start the cleaner
        let cleaner = cleaner::Cleaner::new(db.clone());
        let cleaner_shutdown = Shutdown::new(notify_shutdown_sender.subscribe());
        let cleaner = tokio::task::spawn(cleaner.run(cleaner_shutdown));

        // Start the web app and web server
        let web_server_shutdown = Shutdown::new(notify_shutdown_sender.subscribe());
        let web_server = Self::run_web_app(db.clone(), self.listen_addr, web_server_shutdown);

        // Spawn a task that will notify shutdowns
        tokio::spawn(async move {
            shutdown.await;
            let _result = notify_shutdown_sender.send(()).unwrap();
        });

        web_server.await?;
        exporter.await??;
        cleaner.await??;

        Ok(())
    }
}

fn serve(config: configuration::Config) -> anyhow::Result<()> {
    // Build the Tokio runtime
    let runtime = tokio::runtime::Builder::new_current_thread()
        .worker_threads(4)
        .thread_name("hdas")
        .thread_stack_size(3 * 1024 * 1024)
        .enable_all()
        .build()
        .unwrap();
    let _runtime_guard = runtime.enter();

    let app = App::build(config)?;
    let future = app.run(shutdown_signal());

    // Run the app
    let _ = runtime.block_on(future);

    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install signal handler")
            .recv()
            .await;
    };

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }

    debug!("signal received, starting graceful shutdown");
}

fn main() {
    let config = configuration::get_configuration().expect("Unable to read configuration");

    // Initialize logger
    if std::env::var("RUST_LOG").is_err() {
        std::env::set_var("RUST_LOG", "info,hdas=debug");
    }
    tracing_subscriber::fmt::init();

    // Run the appropriate command

    match serve(config) {
        Ok(()) => {}
        Err(err) => error!(%err, "unable to serve, got err"),
    }
}
