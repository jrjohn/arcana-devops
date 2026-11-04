FROM rust:1.99-slim AS build
WORKDIR /src
COPY Cargo.toml ./
COPY src ./src
COPY Cargo.lock rust-toolchain.toml ./
RUN cargo build --release --locked

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/gh-traffic /usr/local/bin/gh-traffic
ENTRYPOINT ["gh-traffic"]
CMD ["collect"]
