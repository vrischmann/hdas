set export

RUST_LOG := "info"

default: dev

dev:
	sqlx database setup
	cargo sqlx prepare -- --all-targets --all-features
	cargo watch -x run

check:
	sqlx database setup
	DATABASE_NAME=servare cargo watch -x 'check --all-targets --all-features'

clippy:
	cargo clippy --                               \
		-Aclippy::uninlined_format_args       \
		--deny=warnings

prepare:
	cargo sqlx prepare -- --all-targets --all-features

install-tools:
	cargo install sqlx-cli --no-default-features --features rustls,sqlite,postgres
	cargo install cargo-watch cargo-deb grcov

test:
	cargo test

cover:
	RUSTFLAGS="-Cinstrument-coverage" cargo build
	RUSTFLAGS="-Cinstrument-coverage" LLVM_PROFILE_FILE="your_name-%p-%m.profraw" cargo test
	grcov . -s . --binary-path ./target/debug/ -t html --branch --ignore-not-existing -o ./target/debug/coverage/
