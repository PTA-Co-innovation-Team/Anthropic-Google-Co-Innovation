# syntax=docker/dockerfile:1.7
# =============================================================================
# Dev Portal — nginx-served static site.
#
# Cloud Run requires the container to listen on $PORT. nginx needs that
# baked into its config, so we use the /etc/nginx/templates mechanism
# from the official nginx image: any file in that dir is envsubst'd at
# startup and dropped into /etc/nginx/conf.d/.
#
# The Docker image is tiny (~10 MB) and has no runtime state.
# =============================================================================

FROM nginx:1.27-alpine

# Remove the default server block so ours is the only one.
RUN rm -f /etc/nginx/conf.d/default.conf

# Write a template config. nginx:alpine's entrypoint (docker-entrypoint.sh)
# runs envsubst over files in /etc/nginx/templates/ on startup, so $PORT
# from Cloud Run is honored without any wrapper script.
#
# IMPORTANT: The envsubst is limited to $NGINX_ENVSUBST_TEMPLATE_VARS by
# default (all env vars). We only reference $PORT.
RUN mkdir -p /etc/nginx/templates
COPY <<'EOF' /etc/nginx/templates/default.conf.template
server {
    # Cloud Run sets PORT. The envsubst step replaces ${PORT} at
    # container startup.
    listen       ${PORT};
    server_name  _;

    # Disable the version in Server headers — small opsec win.
    server_tokens off;

    # Site root is baked into the image (see COPY below).
    root   /usr/share/nginx/html;
    index  index.html;

    # Serve files; fall through to index.html on 404 so SPA-style
    # deep links still work if anyone adds client-side routing later.
    location / {
        try_files $uri $uri/ /index.html;
    }

    # A tiny healthcheck for Cloud Run probes. Must come before the
    # static handler so it's not intercepted by try_files.
    location = /healthz {
        access_log off;
        return 200 'ok';
        add_header Content-Type text/plain;
    }
}
EOF

# Copy the static site. The deploy script runs envsubst over
# index.html BEFORE building the image, so URL placeholders
# (__LLM_GATEWAY_URL__, etc.) are already substituted by this point.
COPY public/ /usr/share/nginx/html/

# Cloud Run honors whatever $PORT we're told at runtime. Default to
# 8080 for local docker runs.
ENV PORT=8080
EXPOSE 8080
