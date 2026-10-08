# A stand-in for a computer with Syncthing installed, for --use-host-syncthing: Syncthing
# runs as an ordinary program of the user `user`, and there is no Docker inside. IMAGE is
# compose.yaml's, so the fixture runs the same Syncthing as the container.
ARG IMAGE
FROM ${IMAGE}
RUN apk add --no-cache bash && adduser -D -u 5678 user
