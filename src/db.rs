use sqlx::postgres::{PgConnectOptions, PgPool, PgPoolOptions};
use sqlx::ConnectOptions;
use std::fmt;
use std::str::FromStr;

pub struct Db {
    pub pool: PgPool,
}

impl Db {
    pub async fn build(connection_string: &str) -> Result<Self> {
        let mut options = PgConnectOptions::from_str(connection_string)?;
        options.log_statements(log::LevelFilter::Debug);

        let pool = PgPoolOptions::new().connect_with(options).await?;

        sqlx::migrate!("./migrations").run(&pool).await?;

        Ok(Self { pool })
    }
}

pub type Transaction = sqlx::Transaction<'static, sqlx::Postgres>;

#[derive(Debug)]
pub enum Error {
    SQLx(sqlx::Error),
    Migration(sqlx::migrate::MigrateError),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::SQLx(err) => write!(f, "generic sqlx error: {}", err),
            Error::Migration(err) => write!(f, "migration error: {}", err),
        }
    }
}

impl std::error::Error for Error {}

impl From<sqlx::Error> for Error {
    fn from(err: sqlx::Error) -> Error {
        Error::SQLx(err)
    }
}

impl From<sqlx::migrate::MigrateError> for Error {
    fn from(err: sqlx::migrate::MigrateError) -> Error {
        Error::Migration(err)
    }
}

pub type Result<T> = std::result::Result<T, Error>;
