use sqlx::sqlite::{SqliteConnectOptions, SqlitePool, SqlitePoolOptions};
use std::fmt;
use std::str::FromStr;

pub struct Db {
    pub pool: SqlitePool,
}

impl Db {
    pub async fn from_path(path: &str) -> Result<Self> {
        let options = SqliteConnectOptions::from_str(path)?
            .create_if_missing(true)
            .pragma("foreign_keys", "on");
        let pool = SqlitePoolOptions::new().connect_with(options).await?;

        sqlx::migrate!("./migrations").run(&pool).await?;

        Ok(Self { pool })
    }
}

pub type Transaction = sqlx::Transaction<'static, sqlx::Sqlite>;

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
