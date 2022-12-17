use crate::db;
use crate::health_data;
use health_data::{Metric, MetricDataPoint};
use prometheus::Encoder;
use tracing::{error, info};

use std::sync::Arc;

#[derive(Clone)]
pub struct State {
    db: Arc<db::Db>,
}

impl State {
    pub fn new(db: Arc<db::Db>) -> Self {
        Self { db }
    }
}

pub enum HealthDataHandleError {
    Http(http::StatusCode),
    Json(serde_json::Error),
    SQLx(sqlx::Error),
}

impl axum::response::IntoResponse for HealthDataHandleError {
    fn into_response(self) -> axum::response::Response {
        let result = match self {
            Self::Http(code) => (code, code.to_string()),
            Self::Json(err) => (http::StatusCode::INTERNAL_SERVER_ERROR, err.to_string()),
            Self::SQLx(err) => (http::StatusCode::INTERNAL_SERVER_ERROR, err.to_string()),
        };
        result.into_response()
    }
}

impl From<http::StatusCode> for HealthDataHandleError {
    fn from(status_code: http::StatusCode) -> Self {
        Self::Http(status_code)
    }
}

impl From<serde_json::Error> for HealthDataHandleError {
    fn from(err: serde_json::Error) -> Self {
        Self::Json(err)
    }
}

impl From<sqlx::Error> for HealthDataHandleError {
    fn from(err: sqlx::Error) -> Self {
        Self::SQLx(err)
    }
}

pub async fn health_data(
    axum::extract::State(state): axum::extract::State<State>,
    body: axum::body::Bytes,
) -> Result<(http::StatusCode, String), HealthDataHandleError> {
    let db = &state.db;

    // First get a string of the body

    let body_string = match String::from_utf8(body.to_vec()) {
        Ok(body) => body,
        Err(err) => {
            error!(%err, "unable to convert body to a UTF-8 string");
            return Err(http::StatusCode::BAD_REQUEST.into());
        }
    };

    // Parse the body

    let payload: health_data::HealthDataPayload = serde_json::from_str(&body_string)?;

    for metric in payload.data.metrics {
        let mut tx = db.pool.begin().await?;

        let metric_id = insert_metric(&mut tx, &metric).await?;

        if !metric.data.is_empty() {
            info!(
                metric_name = metric.name,
                metric_datapoints = metric.data.len(),
                metric_units = metric.units,
                "got data points",
            );

            for data_point in &metric.data {
                insert_metric_data_point(&mut tx, metric_id, data_point).await?;
            }
        }

        tx.commit().await?;
    }

    Ok((http::StatusCode::ACCEPTED, "Accepted".to_owned()))
}

pub enum MetricsError {
    FromUTF8(std::string::FromUtf8Error),
    Prometheus(prometheus::Error),
}

impl axum::response::IntoResponse for MetricsError {
    fn into_response(self) -> axum::response::Response {
        let body = match self {
            Self::FromUTF8(err) => err.to_string(),
            Self::Prometheus(err) => err.to_string(),
        };

        (http::StatusCode::INTERNAL_SERVER_ERROR, body).into_response()
    }
}

impl From<std::string::FromUtf8Error> for MetricsError {
    fn from(err: std::string::FromUtf8Error) -> Self {
        Self::FromUTF8(err)
    }
}

impl From<prometheus::Error> for MetricsError {
    fn from(err: prometheus::Error) -> Self {
        Self::Prometheus(err)
    }
}

pub async fn metrics() -> Result<String, MetricsError> {
    let mut buffer = Vec::<u8>::new();

    let encoder = prometheus::TextEncoder::new();
    let metric_families = prometheus::gather();
    encoder.encode(&metric_families, &mut buffer)?;

    let result = String::from_utf8(buffer)?;

    Ok(result)
}

async fn insert_metric(tx: &mut db::Transaction, metric: &Metric) -> Result<i64, sqlx::Error> {
    let result = sqlx::query!(
        r#"
        INSERT INTO metric(name, units) VALUES(?, ?)
        ON CONFLICT (name) DO UPDATE SET units = excluded.units
        RETURNING id"#,
        metric.name,
        metric.units,
    )
    .fetch_one(tx)
    .await?;

    Ok(result.id)
}

async fn insert_metric_data_point(
    tx: &mut db::Transaction,
    metric_id: i64,
    data_point: &MetricDataPoint,
) -> Result<(), sqlx::Error> {
    match data_point {
        MetricDataPoint::HeartRate(data_point) => {
            let date_ts = data_point.date.unix_timestamp();

            sqlx::query!(
                r#"
                INSERT INTO data_point_heart_rate(metric_id, date, min, max, avg)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT DO NOTHING"#,
                metric_id,
                date_ts,
                data_point.min,
                data_point.max,
                data_point.avg
            )
            .execute(tx)
            .await?;
        }
        MetricDataPoint::SleepAnalysis(data_point) => {
            let date_ts = data_point.date.unix_timestamp();
            let sleep_start_ts = data_point.sleep_start.unix_timestamp();
            let sleep_end_ts = data_point.sleep_end.unix_timestamp();
            let in_bed_start_ts = data_point.in_bed_start.unix_timestamp();
            let in_bed_end_ts = data_point.in_bed_end.unix_timestamp();

            sqlx::query!(
                r#"
                INSERT INTO data_point_sleep_analysis(
                  metric_id, date,
                  sleep_start, sleep_end, sleep_source,
                  in_bed_start, in_bed_end, in_bed_source,
                  in_bed, asleep
                )
                VALUES(
                  ?, ?,
                  ?, ?, ?,
                  ?, ?, ?,
                  ?, ?
                )
                ON CONFLICT DO NOTHING"#,
                metric_id,
                date_ts,
                sleep_start_ts,
                sleep_end_ts,
                data_point.sleep_source,
                in_bed_start_ts,
                in_bed_end_ts,
                data_point.in_bed_source,
                data_point.in_bed,
                data_point.asleep,
            )
            .execute(tx)
            .await?;
        }
        MetricDataPoint::Generic(data_point) => {
            let date_ts = data_point.date.unix_timestamp();

            sqlx::query!(
                r#"
                INSERT INTO data_point_generic(metric_id, date, quantity)
                VALUES(?, ?, ?)
                ON CONFLICT DO NOTHING"#,
                metric_id,
                date_ts,
                data_point.quantity,
            )
            .execute(tx)
            .await?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;
    use health_data::*;

    async fn get_db() -> db::Db {
        db::Db::from_path("data.db").await.unwrap()
    }

    async fn insert_test_metric(tx: &mut db::Transaction) -> i64 {
        let metric = Metric {
            name: "foobar".to_owned(),
            units: "j/Min".to_owned(),
            data: Vec::new(),
        };

        let metric_id = insert_metric(tx, &metric).await.unwrap();
        assert_eq!(1, metric_id);

        metric_id
    }

    #[tokio::test]
    async fn test_insert_metric() {
        let db = get_db().await;
        let mut tx = db.pool.begin().await.unwrap();

        let metric_id = insert_test_metric(&mut tx).await;

        let metric = sqlx::query!(r#"SELECT name, units FROM metric WHERE id = ?"#, metric_id,)
            .fetch_one(&mut tx)
            .await
            .unwrap();
        assert_eq!("foobar", metric.name.as_str());
    }

    #[tokio::test]
    async fn test_insert_metric_data_point_generic() {
        let db = get_db().await;
        let mut tx = db.pool.begin().await.unwrap();

        let metric_id = insert_test_metric(&mut tx).await;

        let generic_data_point = GenericDataPoint {
            date: time::OffsetDateTime::now_utc(),
            quantity: 234.0,
        };

        insert_metric_data_point(
            &mut tx,
            metric_id,
            &MetricDataPoint::Generic(generic_data_point.clone()),
        )
        .await
        .unwrap();

        let metric = sqlx::query!(
            r#"SELECT date, quantity FROM data_point_generic WHERE metric_id = ?"#,
            metric_id,
        )
        .fetch_one(&mut tx)
        .await
        .unwrap();

        assert_eq!(generic_data_point.date.unix_timestamp(), metric.date);
        assert_eq!(generic_data_point.quantity, metric.quantity);
    }

    #[tokio::test]
    async fn test_insert_metric_data_point_heart_rate() {
        let db = get_db().await;
        let mut tx = db.pool.begin().await.unwrap();

        let metric_id = insert_test_metric(&mut tx).await;

        let data_point = HeartRateDataPoint {
            date: time::OffsetDateTime::now_utc(),
            min: 2.0,
            max: 50.0,
            avg: 25.0,
        };

        insert_metric_data_point(
            &mut tx,
            metric_id,
            &MetricDataPoint::HeartRate(data_point.clone()),
        )
        .await
        .unwrap();

        let metric = sqlx::query!(
            r#"
            SELECT date, min, max, avg
            FROM data_point_heart_rate WHERE metric_id = ?"#,
            metric_id,
        )
        .fetch_one(&mut tx)
        .await
        .unwrap();

        assert_eq!(data_point.date.unix_timestamp(), metric.date);
        assert_eq!(data_point.min, metric.min);
        assert_eq!(data_point.max, metric.max);
        assert_eq!(data_point.avg, metric.avg);
    }

    #[tokio::test]
    async fn test_insert_metric_data_point_sleep_analysis() {
        let db = get_db().await;
        let mut tx = db.pool.begin().await.unwrap();

        let metric_id = insert_test_metric(&mut tx).await;

        let data_point = SleepAnalysisDataPoint {
            date: time::OffsetDateTime::now_utc(),
            asleep: 34.0,
            sleep_source: "foobar".to_owned(),
            sleep_start: time::OffsetDateTime::now_utc(),
            sleep_end: time::OffsetDateTime::now_utc(),
            in_bed: 5012.0,
            in_bed_source: "barbaz".to_owned(),
            in_bed_start: time::OffsetDateTime::now_utc(),
            in_bed_end: time::OffsetDateTime::now_utc(),
        };

        insert_metric_data_point(
            &mut tx,
            metric_id,
            &MetricDataPoint::SleepAnalysis(data_point.clone()),
        )
        .await
        .unwrap();

        let metric = sqlx::query!(
            r#"
            SELECT
              date, sleep_start, sleep_end, sleep_source,
              in_bed_start, in_bed_end, in_bed_source,
              in_bed, asleep
            FROM data_point_sleep_analysis WHERE metric_id = ?"#,
            metric_id,
        )
        .fetch_one(&mut tx)
        .await
        .unwrap();

        assert_eq!(data_point.date.unix_timestamp(), metric.date);
        assert_eq!(data_point.sleep_start.unix_timestamp(), metric.sleep_start);
        assert_eq!(data_point.sleep_end.unix_timestamp(), metric.sleep_end);
        assert_eq!(data_point.sleep_source, metric.sleep_source);
        assert_eq!(
            data_point.in_bed_start.unix_timestamp(),
            metric.in_bed_start
        );
        assert_eq!(data_point.in_bed_end.unix_timestamp(), metric.in_bed_end);
        assert_eq!(data_point.in_bed_source, metric.in_bed_source);
        assert_eq!(data_point.in_bed, metric.in_bed);
        assert_eq!(data_point.asleep, metric.asleep);
    }
}
