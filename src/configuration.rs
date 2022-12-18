use secrecy::{ExposeSecret, Secret};

#[derive(Clone, serde::Deserialize)]
pub struct Config {
    pub database: DatabaseConfig,
    pub application: ApplicationSetttings,
}

#[derive(Clone, serde::Deserialize)]
pub struct ApplicationSetttings {
    pub listen_addr: String,
    pub victoria_addr: String,
}

#[derive(Clone, serde::Deserialize)]
pub struct DatabaseConfig {
    pub username: String,
    pub password: Secret<String>,
    pub port: u16,
    pub host: String,
    pub name: String,
}

impl DatabaseConfig {
    pub fn connection_string(&self) -> Secret<String> {
        Secret::new(format!(
            "postgres://{}:{}@{}:{}/{}",
            self.username,
            self.password.expose_secret(),
            self.host,
            self.port,
            self.name
        ))
    }
}

pub fn get_configuration() -> Result<Config, config::ConfigError> {
    let settings = config::Config::builder()
        .add_source(
            config::File::new("configuration.toml", config::FileFormat::Toml).required(false),
        )
        .add_source(
            config::File::new("/etc/hdas/configuration.toml", config::FileFormat::Toml)
                .required(false),
        )
        .add_source(
            config::Environment::default()
                .try_parsing(true)
                .separator("_"),
        )
        .build()?;

    settings.try_deserialize::<Config>()
}
