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
COPY default.conf.template /etc/nginx/templates/default.conf.template

# Copy the static site. The deploy script runs envsubst over
# index.html BEFORE building the image, so URL placeholders
# (__LLM_GATEWAY_URL__, etc.) are already substituted by this point.
COPY public/ /usr/share/nginx/html/

# Cloud Run honors whatever $PORT we're told at runtime. Default to
# 8080 for local docker runs.
ENV PORT=8080
EXPOSE 8080
