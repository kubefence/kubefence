# kata-sandbox demo image
# Uses python:3.12-slim as the base (matches python-dev profile).
# Adds libdbus-1-3 which the nono binary (dynamically linked) requires.
FROM python:3.12-slim
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends libdbus-1-3 && \
    rm -rf /var/lib/apt/lists/*

# Replace /bin/bash with a nono wrapper so that every exec'd shell is
# automatically sandboxed when /nono/nono is present (bind-mounted by NRI
# inside the Kata VM via virtiofs).  Falls back to real bash when /nono
# is absent (plain pods, image builds, ephemeral debug containers).
#
#   kubectl exec -it <kata-pod>  -- bash  →  auto-sandboxed inside the VM
#   kubectl exec -it <plain-pod> -- bash  →  plain bash, no sandbox
RUN mv /bin/bash /bin/bash.real && \
    { echo '#!/bin/bash.real'; \
      echo '[ -x /nono/nono ] && exec /nono/nono wrap --profile "${NONO_PROFILE:-default}" -- /bin/bash.real "$@"'; \
      echo 'exec /bin/bash.real "$@"'; \
    } > /bin/bash && \
    chmod +x /bin/bash
