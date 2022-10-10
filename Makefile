default: dev

dev:
	sqlx database setup
	cargo sqlx prepare -- --all-targets --all-features
	cargo watch -x run

install-tools:
	cargo install sqlx-cli --no-default-features --features rustls,sqlite,postgres
	cargo install cargo-watch cargo-deb grcov

test:
	cargo test

build-deb:
	RUSTFLAGS="-C target-cpu=ivybridge" cargo deb --target x86_64-unknown-linux-musl --no-strip

cover:
	RUSTFLAGS="-Cinstrument-coverage" cargo build
	RUSTFLAGS="-Cinstrument-coverage" LLVM_PROFILE_FILE="your_name-%p-%m.profraw" cargo test
	grcov . -s . --binary-path ./target/debug/ -t html --branch --ignore-not-existing -o ./target/debug/coverage/
