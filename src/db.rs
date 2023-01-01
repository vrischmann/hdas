use sqlx::postgres::{PgConnectOptions, PgPool, PgPoolOptions};
use sqlx::ConnectOptions;
use std::str::FromStr;

pub struct Db {
    pub pool: PgPool,
}

impl Db {
    pub async fn build(connection_string: &str) -> Result<Self> {
        let mut options = PgConnectOptions::from_str(connection_string)?;
        options.log_statements(log::LevelFilter::Debug);

        let pool = PgPoolOptions::new().connect_with(options).await?;

        sqlx::migrate!("./migrations")
            .run(&pool)
            .await
            .map_err(Error::Migration)?;

        Ok(Self { pool })
    }
}

pub type Transaction = sqlx::Transaction<'static, sqlx::Postgres>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    SQLx(#[from] sqlx::Error),
    #[error("unable to run migrations: {0}")]
    Migration(#[source] sqlx::migrate::MigrateError),
}

pub type Result<T> = std::result::Result<T, Error>;
