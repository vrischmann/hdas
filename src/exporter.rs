use crate::db;
use crate::shutdown::Shutdown;
use std::fmt;
use std::fmt::Write;
use std::io;
use std::net;
use std::sync::Arc;
use std::time;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tracing::{debug, error, info};

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

pub struct Exporter {
    db: Arc<db::Db>,
    addr: net::SocketAddr,
    stream: Option<TcpStream>,
}

impl Exporter {
    pub fn new(db: Arc<db::Db>, addr: net::SocketAddr) -> Self {
        Self {
            db,
            addr,
            stream: None,
        }
    }

    pub async fn run(mut self, mut shutdown: Shutdown) -> Result<()> {
        let mut interval = tokio::time::interval(time::Duration::from_secs(1));

        'outer_loop: loop {
            tokio::select! {
                _ = shutdown.recv() => {
                    info!("exporter shutting down");
                    break 'outer_loop;
                },
                _ = interval.tick() => {
                    match self.do_export().await {
                        Ok(_) => {},
                        Err(err) => error!(%err, "unable to export data"),
                    }
                },
            }
        }

        if let Some(stream) = self.stream {
            drop(stream);
        }

        Ok(())
    }

    async fn connect(&mut self) -> Result<&mut TcpStream> {
        match self.stream {
            Some(ref mut s) => Ok(s),
            None => {
                debug!(addr = self.addr.to_string(), "connecting to VM");

                let stream = TcpStream::connect(self.addr).await?;
                self.stream = Some(stream);

                // Safe because we know it's there
                Ok(self.stream.as_mut().unwrap())
            }
        }
    }

    async fn do_export(&mut self) -> Result<()> {
        let mut exported: usize = 0;
        let mut commands_buffer = String::new();

        // Generate all the export commands

        self.gen_export_heart_rate_commands(&mut commands_buffer, &mut exported)
            .await?;
        for metric_type in ALL_GENERIC_METRIC_TYPES {
            self.gen_export_generic_commands(&mut commands_buffer, metric_type, &mut exported)
                .await?;
        }
        self.gen_export_sleep_analysis_commands(&mut commands_buffer, &mut exported)
            .await?;

        // Send them to Victoria
        let stream = self.connect().await?;
        stream.write_all(commands_buffer.as_bytes()).await?;

        if exported > 0 {
            info!(exported = exported, "exported data points");
        }

        Ok(())
    }

    async fn gen_export_heart_rate_commands(
        &mut self,
        commands_buffer: &mut String,
        exported: &mut usize,
    ) -> Result<()> {
        // Get the data and write the export commands to the buffer

        let rows = sqlx::query!(
            r#"
            SELECT d.id, d.max, d.date
            FROM data_point_heart_rate d
            INNER JOIN metric m ON d.metric_id = m.id
            WHERE m.name = 'heart_rate'
            AND d.exported = 0"#,
        )
        .fetch_all(&self.db.pool)
        .await?;

        let mut ids = Vec::<i64>::new();
        for row in rows {
            writeln!(
                commands_buffer,
                "put health_data_heart_rate {} {} ",
                row.date, row.max
            )?;

            ids.push(row.id);
        }

        // Mark all data points as exported

        *exported += ids.len();

        let mut tx = self.db.pool.begin().await?;
        for id in ids {
            sqlx::query!(
                r#"
                UPDATE data_point_heart_rate
                SET exported = 1
                WHERE id = $1"#,
                id,
            )
            .execute(&mut tx)
            .await?;
        }
        tx.commit().await?;

        Ok(())
    }

    async fn gen_export_generic_commands(
        &mut self,
        commands_buffer: &mut String,
        metric_type: GenericMetricType,
        exported: &mut usize,
    ) -> Result<()> {
        let metric_name = metric_type.to_string();

        // Get the data and write the export commands to the buffer

        let rows = sqlx::query!(
            r#"
            SELECT d.id, d.quantity, d.date
            FROM data_point_generic d
            INNER JOIN metric m ON d.metric_id = m.id
            WHERE m.name = $1
            AND d.exported = 0
            "#,
            metric_name,
        )
        .fetch_all(&self.db.pool)
        .await?;

        let mut ids = Vec::<i64>::new();
        for row in rows {
            writeln!(
                commands_buffer,
                "put health_data_{} {} {} ",
                metric_name, row.date, row.quantity
            )?;

            ids.push(row.id);
        }

        // Mark all data points as exported

        *exported += ids.len();

        let mut tx = self.db.pool.begin().await?;
        for id in ids {
            sqlx::query!(
                r#"
                UPDATE data_point_generic
                SET exported = 1
                WHERE id = $1"#,
                id,
            )
            .execute(&mut tx)
            .await?;
        }
        tx.commit().await?;

        Ok(())
    }

    async fn gen_export_sleep_analysis_commands(
        &mut self,
        commands_buffer: &mut String,
        exported: &mut usize,
    ) -> Result<()> {
        // Get the data and write the export commands to the buffer

        let rows = sqlx::query!(
            r#"
            SELECT d.id, d.in_bed, d.asleep, d.date
            FROM data_point_sleep_analysis d
            INNER JOIN metric m ON d.metric_id = m.id
            WHERE m.name = 'sleep_analysis'
            AND d.exported = 0"#,
        )
        .fetch_all(&self.db.pool)
        .await?;

        let mut ids = Vec::<i64>::new();
        for row in rows {
            writeln!(
                commands_buffer,
                "put health_data_sleep_analysis {} {} type=in_bed",
                row.date, row.in_bed,
            )?;
            writeln!(
                commands_buffer,
                "put health_data_sleep_analysis {} {} type=asleep",
                row.date, row.asleep,
            )?;

            ids.push(row.id);
        }

        // Mark all data points as exported

        *exported += ids.len();

        let mut tx = self.db.pool.begin().await?;
        for id in ids {
            sqlx::query!(
                r#"
                UPDATE data_point_sleep_analysis
                SET exported = 1
                WHERE id = $1"#,
                id,
            )
            .execute(&mut tx)
            .await?;
        }
        tx.commit().await?;

        Ok(())
    }
}

const ALL_GENERIC_METRIC_TYPES: [GenericMetricType; 5] = [
    GenericMetricType::WeightBodyMass,
    GenericMetricType::WalkingHeartRateAverage,
    GenericMetricType::RestingHeartRate,
    GenericMetricType::WalkingRunningDistance,
    GenericMetricType::WalkingSpeed,
];

enum GenericMetricType {
    WeightBodyMass,
    WalkingHeartRateAverage,
    RestingHeartRate,
    WalkingRunningDistance,
    WalkingSpeed,
}

impl fmt::Display for GenericMetricType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Self::WeightBodyMass => write!(f, "weight_body_mass"),
            Self::WalkingHeartRateAverage => write!(f, "walking_heart_rate_average"),
            Self::RestingHeartRate => write!(f, "resting_heart_rate"),
            Self::WalkingRunningDistance => write!(f, "walking_running_distance"),
            Self::WalkingSpeed => write!(f, "walking_speed"),
        }
    }
}
