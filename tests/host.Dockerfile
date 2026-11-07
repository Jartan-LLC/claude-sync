# A stand-in for a computer with Syncthing installed, for --use-host-syncthing: Syncthing
# runs as an ordinary program of the user `user`, and there is no Docker inside. IMAGE is
# compose.yaml's, so the fixture runs the same Syncthing as the container. GNU tar replaces
# BusyBox's, as on most Linux hosts, for backups there.
ARG IMAGE
FROM ${IMAGE}
RUN apk add --no-cache bash tar && adduser -D -u 5678 user
