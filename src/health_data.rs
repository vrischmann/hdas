use serde::Deserialize;
use time::OffsetDateTime;

time::serde::format_description!(
    custom_format,
    OffsetDateTime,
    "[year]-[month]-[day] [hour]:[minute]:[second] [offset_hour][offset_minute]"
);

#[derive(Clone, Deserialize, Debug, PartialEq)]
pub struct GenericDataPoint {
    #[serde(with = "custom_format")]
    pub date: OffsetDateTime,
    #[serde(rename(deserialize = "qty"))]
    pub quantity: f64,
}

#[derive(Clone, Deserialize, Debug, PartialEq)]
pub struct HeartRateDataPoint {
    #[serde(with = "custom_format")]
    pub date: OffsetDateTime,
    #[serde(rename(deserialize = "Min"))]
    pub min: f64,
    #[serde(rename(deserialize = "Max"))]
    pub max: f64,
    #[serde(rename(deserialize = "Avg"))]
    pub avg: f64,
}

#[derive(Clone, Deserialize, Debug, PartialEq)]
pub struct SleepAnalysisDataPoint {
    pub asleep: f64,
    #[serde(with = "custom_format")]
    pub date: OffsetDateTime,
    #[serde(rename(deserialize = "sleepSource"))]
    pub sleep_source: String,
    #[serde(with = "custom_format", rename(deserialize = "sleepStart"))]
    pub sleep_start: OffsetDateTime,
    #[serde(with = "custom_format", rename(deserialize = "sleepEnd"))]
    pub sleep_end: OffsetDateTime,
    #[serde(rename(deserialize = "inBed"))]
    pub in_bed: f64,
    #[serde(rename(deserialize = "inBedSource"))]
    pub in_bed_source: String,
    #[serde(with = "custom_format", rename(deserialize = "inBedStart"))]
    pub in_bed_start: OffsetDateTime,
    #[serde(with = "custom_format", rename(deserialize = "inBedEnd"))]
    pub in_bed_end: OffsetDateTime,
}

#[derive(Deserialize, Debug, PartialEq)]
#[serde(untagged)]
pub enum MetricDataPoint {
    HeartRate(HeartRateDataPoint),
    SleepAnalysis(SleepAnalysisDataPoint),
    Generic(GenericDataPoint),
}

#[derive(Deserialize, Debug, PartialEq)]
pub struct Metric {
    pub name: String,
    pub units: String,
    pub data: Vec<MetricDataPoint>,
}

#[derive(Deserialize, Debug, PartialEq)]
pub struct HealthData {
    pub metrics: Vec<Metric>,
}

#[derive(Deserialize, Debug, PartialEq)]
pub struct HealthDataPayload {
    pub data: HealthData,
}

#[cfg(test)]
mod tests {
    use super::*;
    use time::macros::{datetime, format_description};

    static FORMAT_DESCRIPTION: &[time::format_description::FormatItem] = format_description!(
        "[year]-[month]-[day] [hour]:[minute]:[second] [offset_hour][offset_minute]"
    );

    #[test]
    fn parse_metric() {
        let input = r#"{"data":[{"Avg":83.15994644165039,"Max":85,"Min":81.31989288330078,"date":"2022-07-23 00:01:41 +0200"},{"Avg":76,"Max":76,"Min":76,"date":"2022-07-23 00:04:48 +0200"}],"name":"heart_rate","units":"count/min"}"#;

        let exp = Metric {
            name: "heart_rate".to_owned(),
            units: "count/min".to_owned(),
            data: vec![
                MetricDataPoint::HeartRate(HeartRateDataPoint {
                    date: datetime!(2022-07-23 00:01:41 +2),
                    avg: 83.15994644165039,
                    max: 85.0,
                    min: 81.31989288330078,
                }),
                MetricDataPoint::HeartRate(HeartRateDataPoint {
                    date: datetime!(2022-07-23 00:04:48 +2),
                    avg: 76.0,
                    max: 76.0,
                    min: 76.0,
                }),
            ],
        };

        let metric: Metric = serde_json::from_str(input).unwrap();
        assert_eq!(exp, metric);
    }

    #[test]
    fn parse_custom_format() {
        let input = "2022-07-23 08:13:00 +0200";
        let exp = datetime!(2022-07-23 08:13:00 +2);

        let dt = OffsetDateTime::parse(input, FORMAT_DESCRIPTION).unwrap();
        assert_eq!(exp, dt);
    }

    #[test]
    fn deserialize_generic_data_point() {
        let data = r#"{"date":"2022-07-23 08:13:00 +0200","qty":3.924}"#;

        let exp = GenericDataPoint {
            date: datetime!(2022-07-23 08:13:00 +2),
            quantity: 3.924,
        };

        let data_point: GenericDataPoint = serde_json::from_str(data).unwrap();
        assert_eq!(exp, data_point);
    }

    #[test]
    fn deserialize_heart_rate_data_point() {
        let data = r#"
          {
            "Avg": 66,
            "Max": 66,
            "Min": 66,
            "date": "2022-07-24 15:21:29 +0200"
          }"#;

        let exp = HeartRateDataPoint {
            date: datetime!(2022-07-24 15:21:29 +2),
            avg: 66.0,
            max: 66.0,
            min: 66.0,
        };

        let data_point: HeartRateDataPoint = serde_json::from_str(data).unwrap();
        assert_eq!(exp, data_point);
    }

    #[test]
    fn deserialize_sleep_analysis_data_point() {
        let data = r#"
          {
            "asleep": 5.6499999999999995,
            "date": "2022-07-23 00:22:33 +0200",
            "inBed": 5.627450701958604,
            "inBedEnd": "2022-07-23 06:00:11 +0200",
            "inBedSource": "José",
            "inBedStart": "2022-07-23 00:22:33 +0200",
            "sleepEnd": "2022-07-23 05:59:19 +0200",
            "sleepSource": "Foobar",
            "sleepStart": "2022-07-23 00:17:49 +0200"
          }"#;

        let exp = SleepAnalysisDataPoint {
            asleep: 5.6499999999999995,
            date: datetime!(2022-07-23 00:22:33 +2),
            in_bed: 5.627450701958604,
            in_bed_source: "José".to_owned(),
            in_bed_end: datetime!(2022-07-23 06:00:11 +2),
            in_bed_start: datetime!(2022-07-23 00:22:33 +2),
            sleep_source: "Foobar".to_owned(),
            sleep_end: datetime!(2022-07-23 05:59:19 +2),
            sleep_start: datetime!(2022-07-23 00:17:49 +2),
        };

        let data_point: SleepAnalysisDataPoint = serde_json::from_str(data).unwrap();
        assert_eq!(exp, data_point);
    }
}
