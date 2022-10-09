use core::future::Future;

use log::{debug, error, info};
use shutdown::Shutdown;
use std::net;
use std::str::FromStr;
use std::sync::Arc;

mod db;
mod exporter;
mod health_data;
mod shutdown;
mod web;

async fn fallback_handler() -> (http::StatusCode, String) {
    (http::StatusCode::NOT_FOUND, "Page Not Found".to_owned())
}

struct App {
    db_path: String,
    listen_addr: net::SocketAddr,
    victoria_addr: net::SocketAddr,
}

impl App {
    fn new(db_path: String, listen_addr: net::SocketAddr, victoria_addr: net::SocketAddr) -> Self {
        Self {
            db_path,
            listen_addr,
            victoria_addr,
        }
    }

    async fn run_web_app(
        db: Arc<db::Db>,
        listen_addr: net::SocketAddr,
        mut shutdown: Shutdown,
    ) -> anyhow::Result<()> {
        let state = web::State::new(db);

        // Build the router
        let web_app = axum::Router::with_state(state)
            .route("/health_data", axum::routing::post(web::health_data))
            .route("/metrics", axum::routing::get(web::metrics))
            .fallback(fallback_handler)
            .layer(tower_http::trace::TraceLayer::new_for_http());

        let web_server = axum::Server::bind(&listen_addr)
            .serve(web_app.into_make_service())
            .with_graceful_shutdown(shutdown.recv());

        Ok(web_server.await?)
    }

    async fn run(self, shutdown: impl Future + std::marker::Send + 'static) -> anyhow::Result<()> {
        // Used for shutdown notinfications
        let (notify_shutdown_sender, _) = tokio::sync::broadcast::channel(2);

        // Initialize the database
        let db = Arc::new(db::Db::from_path(&self.db_path).await?);

        // Start the exporter
        let exporter = exporter::Exporter::new(db.clone(), self.victoria_addr);
        let exporter_shutdown = Shutdown::new(notify_shutdown_sender.subscribe());
        let exporter = tokio::task::spawn(exporter.run(exporter_shutdown));

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

        Ok(())
    }
}

fn serve(args: &clap::ArgMatches) -> anyhow::Result<()> {
    let db_path = args.get_one::<String>("db").unwrap(); // Safe because clap enforces we get a value

    let listen_addr = args
        .get_one::<String>("listen-addr")
        .map(|addr| std::net::SocketAddr::from_str(addr).expect("expected a valid listen address"))
        .unwrap(); // Safe because clap enforces we get a value
    info!("listen addr: {}", listen_addr);

    let victoria_addr = args
        .get_one::<String>("victoria-addr")
        .map(|addr| {
            std::net::SocketAddr::from_str(addr).expect("expected a valid VictoriaMetrics address")
        })
        .unwrap(); // Safe because clap enforces we get a value
    info!("victoria addr: {}", victoria_addr);

    // Build the Tokio runtime

    let runtime = tokio::runtime::Builder::new_current_thread()
        .worker_threads(4)
        .thread_name("hdas")
        .thread_stack_size(3 * 1024 * 1024)
        .enable_all()
        .build()
        .unwrap();
    let _runtime_guard = runtime.enter();

    let app = App::new(db_path.to_string(), listen_addr, victoria_addr);
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
    let root_command = clap::Command::new("hdas")
        .version(clap::crate_version!())
        .about("Health Data API Server")
        .arg(
            clap::Arg::new("listen-addr")
                .long("listen-addr")
                .help("listening address")
                .takes_value(true)
                .default_value("127.0.0.1:5804")
                .value_name("ADDR"),
        )
        .arg(
            clap::Arg::new("victoria-addr")
                .long("victoria-addr")
                .help("Victoria Metrics address")
                .takes_value(true)
                .default_value("127.0.0.1:4242")
                .value_name("ADDR"),
        )
        .arg(
            clap::Arg::new("db")
                .long("db")
                .help("database path")
                .takes_value(true)
                .default_value("data.db")
                .value_name("pATH"),
        );

    let matches = root_command.get_matches();

    // Initialize logger
    if std::env::var("RUST_LOG").is_err() {
        std::env::set_var("RUST_LOG", "hdas=debug");
    }
    pretty_env_logger::init();

    // Run the appropriate command

    match serve(&matches) {
        Ok(()) => {}
        Err(err) => error!("unable to serve, got err {}", err),
    }
}
