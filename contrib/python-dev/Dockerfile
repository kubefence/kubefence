# python-dev demo image
# Adds libdbus-1-3 which the nono binary (dynamically linked) requires at runtime.
FROM python:3.12-slim
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends libdbus-1-3 && \
    rm -rf /var/lib/apt/lists/*

# Replace /bin/bash with a nono wrapper so that every exec'd shell is
# automatically sandboxed when /nono/nono is present (bind-mounted by the NRI
# plugin). Falls back to the real bash when /nono is absent (baseline pods,
# image builds, ephemeral debug containers).
#
# This means:
#   kubectl exec -it <sandbox-pod> -- bash   →  sandboxed automatically
#   kubectl exec -it <baseline-pod> -- bash  →  plain bash, no sandbox
#
# Profile can be overridden per-pod via the NONO_PROFILE env var.
RUN mv /bin/bash /bin/bash.real && \
    { echo '#!/bin/bash.real'; \
      echo '[ -x /nono/nono ] && exec /nono/nono wrap --profile "${NONO_PROFILE:-default}" -- /bin/bash.real "$@"'; \
      echo 'exec /bin/bash.real "$@"'; \
    } > /bin/bash && \
    chmod +x /bin/bash
