# musl build so the binary runs on the docker:cli (alpine) image, which brings the docker CLI
# the container checks need.
FROM rust:1.99-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY src ./src
RUN cargo build --release --locked

FROM docker:cli
COPY --from=build /src/target/release/ci-health /usr/local/bin/ci-health
ENTRYPOINT ["ci-health"]
