CREATE TABLE IF NOT EXISTS metric(
  id bigint primary key generated always as identity,
  name text not null,
  units text not null,
  UNIQUE (name)
);

CREATE TABLE IF NOT EXISTS data_point_generic(
  id bigint primary key generated always as identity,
  metric_id bigint not null,
  date timestamptz not null,
  quantity double precision not null default 0,
  exported boolean not null default false,
  UNIQUE (id, metric_id, date),
  FOREIGN KEY (metric_id) REFERENCES metric(id)
);
CREATE INDEX IF NOT EXISTS data_point_generic_exported_idx ON data_point_generic(exported);

CREATE TABLE IF NOT EXISTS data_point_heart_rate(
  id bigint primary key generated always as identity,
  metric_id bigint not null,
  date timestamptz not null,
  min double precision not null default 0,
  max double precision not null default 0,
  avg double precision not null default 0,
  exported boolean not null default false,
  UNIQUE (id, metric_id, date),
  FOREIGN KEY (metric_id) REFERENCES metric(id)
);
CREATE INDEX IF NOT EXISTS data_point_heart_rate_exported_idx ON data_point_heart_rate(exported);

CREATE TABLE IF NOT EXISTS data_point_sleep_analysis(
  id bigint primary key generated always as identity,
  metric_id bigint not null,
  date timestamptz not null,
  sleep_start timestamptz NOT NULL,
  sleep_end timestamptz not null,
  sleep_source text not null,
  in_bed_start timestamptz not null,
  in_bed_end timestamptz not null,
  in_bed_source text not null,
  in_bed double precision not null,
  asleep double precision not null,
  exported boolean not null default false,
  UNIQUE (id, metric_id, date),
  FOREIGN KEY (metric_id) REFERENCES metric(id)
);
CREATE INDEX IF NOT EXISTS data_point_sleep_analysis_exported_idx ON data_point_sleep_analysis(exported);
