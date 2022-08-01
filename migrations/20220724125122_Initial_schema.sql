CREATE TABLE IF NOT EXISTS metric(
  id integer PRIMARY KEY NOT NULL,
  name text NOT NULL,
  units text NOT NULL,
  UNIQUE (name)
);

CREATE TABLE IF NOT EXISTS data_point_generic(
  id integer PRIMARY KEY NOT NULL,
  metric_id integer NOT NULL,
  date integer NOT NULL,
  quantity real NOT NULL DEFAULT 0,
  exported integer NOT NULL DEFAULT 0,
  UNIQUE (id, metric_id, date),
  FOREIGN KEY (metric_id) REFERENCES metric(id)
);
CREATE INDEX IF NOT EXISTS data_point_generic_exported_idx ON data_point_generic(exported);

CREATE TABLE IF NOT EXISTS data_point_heart_rate(
  id integer PRIMARY KEY NOT NULL,
  metric_id integer NOT NULL,
  date integer NOT NULL,
  min real NOT NULL DEFAULT 0,
  max real NOT NULL DEFAULT 0,
  avg real NOT NULL DEFAULT 0,
  exported integer NOT NULL DEFAULT 0,
  UNIQUE (id, metric_id, date),
  FOREIGN KEY (metric_id) REFERENCES metric(id)
);
CREATE INDEX IF NOT EXISTS data_point_heart_rate_exported_idx ON data_point_heart_rate(exported);

CREATE TABLE IF NOT EXISTS data_point_sleep_analysis(
  id integer PRIMARY KEY NOT NULL,
  metric_id integer NOT NULL,
  date integer NOT NULL,
  sleep_start integer NOT NULL,
  sleep_end integer NOT NULL,
  sleep_source text NOT NULL,
  in_bed_start integer NOT NULL,
  in_bed_end integer NOT NULL,
  in_bed_source text NOT NULL,
  in_bed real NOT NULL,
  asleep real NOT NULL,
  exported integer NOT NULL DEFAULT 0,
  UNIQUE (id, metric_id, date),
  FOREIGN KEY (metric_id) REFERENCES metric(id)
);
CREATE INDEX IF NOT EXISTS data_point_sleep_analysis_exported_idx ON data_point_sleep_analysis(exported);
