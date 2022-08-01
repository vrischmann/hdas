default: dev

dev:
	sqlx database setup
	cargo sqlx prepare -- --tests
