# node-dev demo image
# Adds libdbus-1-3 which the nono binary (dynamically linked) requires at runtime.
FROM node:20-slim
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends libdbus-1-3 && \
    rm -rf /var/lib/apt/lists/*
