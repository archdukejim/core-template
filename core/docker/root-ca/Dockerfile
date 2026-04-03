# Root CA Container
#
# Builds a self-contained signing container with:
#   - Root CA certificate baked into the image
#   - Root CA private key injected via BuildKit secret (NOT in image layers)
#   - sign-certs.sh as the entrypoint (subcommands: sign-intermediate, sign-leaf, verify)
#
# Build (from repo root):
#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=root_key,src=/opt/stepca/data/secrets/root_ca.key \
#     -t root-ca:local \
#     core/docker/root-ca/
#
# Runtime mounts (required):
#   --mount type=bind,src=/opt/stepca/data/secrets/root_ca.key,target=/secrets/root_ca.key,readonly
#   -v /opt/root-ca/history:/history
#   -v /opt/root-ca/revokes:/revokes
#   -v /tmp/root-ca-out:/out
#
# SECURITY: This image contains the root CA certificate but NOT the private key.
# The key is mounted at runtime and is never written to any image layer.
# Never push this image to a public or shared registry.

FROM alpine:3.20

RUN apk add --no-cache openssl

# CA cert is safe to bake in — it is public by definition
COPY root_ca.crt       /ca/root_ca.crt
COPY intermediate_ext.cnf /ca/intermediate_ext.cnf
COPY sign-certs.sh     /usr/local/bin/sign-certs.sh

RUN chmod +x /usr/local/bin/sign-certs.sh && \
    mkdir -p /history /revokes /out /secrets

ENV ROOT_CA_CRT=/ca/root_ca.crt
ENV ROOT_CA_KEY=/secrets/root_ca.key

VOLUME ["/history", "/revokes", "/out"]

ENTRYPOINT ["/usr/local/bin/sign-certs.sh"]
CMD ["help"]
