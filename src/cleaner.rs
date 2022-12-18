use crate::db;
use crate::shutdown::Shutdown;
use std::fmt;
use std::io;
use std::sync::Arc;
use std::time;
use tracing::{error, info};

#[derive(Debug)]
pub enum Error {
    IO(io::Error),
    SQLx(sqlx::Error),
    Fmt(fmt::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::IO(err) => write!(f, "{}", err),
            Self::SQLx(err) => write!(f, "{}", err),
            Self::Fmt(err) => write!(f, "{}", err),
        }
    }
}

impl std::error::Error for Error {}

impl From<io::Error> for Error {
    fn from(err: io::Error) -> Error {
        Error::IO(err)
    }
}

impl From<sqlx::Error> for Error {
    fn from(err: sqlx::Error) -> Error {
        Error::SQLx(err)
    }
}

impl From<fmt::Error> for Error {
    fn from(err: fmt::Error) -> Error {
        Error::Fmt(err)
    }
}

pub type Result<T> = std::result::Result<T, Error>;

pub struct Cleaner {
    db: Arc<db::Db>,
}

impl Cleaner {
    pub fn new(db: Arc<db::Db>) -> Self {
        Self { db }
    }

    pub async fn run(mut self, mut shutdown: Shutdown) -> Result<()> {
        let mut interval = tokio::time::interval(time::Duration::from_secs(600));

        'outer_loop: loop {
            tokio::select! {
                _ = shutdown.recv() => {
                    info!("cleaner shutting down");
                    break 'outer_loop;
                },
                _ = interval.tick() => {
                    match self.do_clean().await {
                        Ok(_) => {},
                        Err(err) => error!(%err, "unable to clean data"),
                    }
                },
            }
        }

        Ok(())
    }

    async fn do_clean(&mut self) -> Result<()> {
        let mut tx = self.db.pool.begin().await?;

        let result1 = sqlx::query!(r#"DELETE FROM data_point_heart_rate WHERE exported = true"#)
            .execute(&mut tx)
            .await?;

        let result2 = sqlx::query!(r#"DELETE FROM data_point_generic WHERE exported = true"#)
            .execute(&mut tx)
            .await?;

        let result3 =
            sqlx::query!(r#"DELETE FROM data_point_sleep_analysis WHERE exported = true"#)
                .execute(&mut tx)
                .await?;

        tx.commit().await?;

        let nb_cleaned =
            result1.rows_affected() + result2.rows_affected() + result3.rows_affected();

        info!(nb_cleaned, "cleaned");

        Ok(())
    }
}
