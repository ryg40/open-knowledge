# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

ARG NODE_IMAGE=node:24-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20
ARG OK_VERSION=0.83.2

FROM ${NODE_IMAGE} AS native
ARG OK_VERSION
ARG TARGETARCH
ARG OK_NPM_INTEGRITY=sha512-SdAjilt0vHnGsMPhBBP0WyAWeQJ4FZl+uQX0VKCEx7v41/0PjL0VHLORzBmjZ3RwYPCzm4xNSFVG7E80on+Xdw==
ENV OK_NPM_TARBALL=https://registry.npmjs.org/@inkeep/open-knowledge/-/open-knowledge-${OK_VERSION}.tgz \
    OK_NPM_INTEGRITY=${OK_NPM_INTEGRITY}
WORKDIR /native
RUN <<EOF
set -eu
node --input-type=module -e "
import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
const response = await fetch(process.env.OK_NPM_TARBALL);
if (!response.ok) throw new Error('download failed: HTTP ' + response.status);
const tarball = Buffer.from(await response.arrayBuffer());
const actual = 'sha512-' + createHash('sha512').update(tarball).digest('base64');
if (actual !== process.env.OK_NPM_INTEGRITY) {
  console.error('integrity mismatch: expected ' + process.env.OK_NPM_INTEGRITY + ' got ' + actual);
  process.exit(1);
}
writeFileSync('npm-package.tgz', tarball);
"
tar -xzf npm-package.tgz package/dist/native
mkdir -p out
cp package/dist/native/index.js package/dist/native/index.d.ts package/dist/native/*.node out/
test "$(find out -name '*.node' | wc -l)" -eq 8
case "${TARGETARCH:-$(uname -m)}" in
  amd64|x86_64) addon=x64 ;;
  arm64|aarch64) addon=arm64 ;;
  *) echo "unsupported target architecture: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;;
esac
test -f "out/native-config.linux-$addon-gnu.node"
EOF

FROM ${NODE_IMAGE} AS build
ENV CI=true \
    PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH
WORKDIR /src
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY patches ./patches
RUN npm install -g "pnpm@$(node -p "require('./package.json').packageManager.split('@')[1]")" \
 && pnpm --version
RUN pnpm fetch
COPY . .
RUN pnpm install --frozen-lockfile --offline
ARG OK_RELEASE_VERSION=
RUN <<'EOF'
set -eu
if [ -n "${OK_RELEASE_VERSION}" ]; then
  for pkg in cli core server app desktop; do
    node -e "
const fs = require('node:fs');
const file = process.argv[1];
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
manifest.version = process.argv[2];
fs.writeFileSync(file, JSON.stringify(manifest, null, 2) + '\n');
" "packages/${pkg}/package.json" "${OK_RELEASE_VERSION}"
  done
  for skill in packages/server/assets/skills/project/SKILL.md packages/server/assets/skills/discovery/SKILL.md; do
    sed -i -E "s/^([[:space:]]+version:[[:space:]]+\")[^\"]+(\".*)$/\1${OK_RELEASE_VERSION}\2/" "${skill}"
  done
fi
node -p "require('./packages/cli/package.json').version"
EOF
COPY --from=native /native/out/ ./packages/native-config/
RUN pnpm --filter "@inkeep/open-knowledge..." --filter "!@inkeep/open-knowledge-native-config" run build
RUN mkdir -p /out \
 && cd packages/cli \
 && pnpm pack --pack-destination /out \
 && pnpm --filter @inkeep/open-knowledge deploy --legacy --prod --config.allow-unused-patches=true /opt/open-knowledge \
 && node /opt/open-knowledge/dist/cli.mjs --version

FROM scratch AS artifacts
COPY --from=native /native/npm-package.tgz /npm/
COPY --from=build /out/ /source/

FROM ${NODE_IMAGE} AS runtime
ARG OK_VERSION
ARG OK_REVISION=unknown
ARG OK_SOURCE=https://github.com/inkeep/open-knowledge
ARG OK_UID=10001
ARG OK_GID=10001
LABEL org.opencontainers.image.title="OpenKnowledge" \
      org.opencontainers.image.source="${OK_SOURCE}" \
      org.opencontainers.image.revision="${OK_REVISION}" \
      org.opencontainers.image.version="${OK_VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid "${OK_GID}" openknowledge \
 && useradd --uid "${OK_UID}" --gid "${OK_GID}" --create-home --home-dir /home/openknowledge --shell /usr/sbin/nologin openknowledge \
 && mkdir -p /data \
 && chown "${OK_UID}:${OK_GID}" /data
COPY --from=build /opt/open-knowledge /opt/open-knowledge
RUN ln -s /opt/open-knowledge/dist/cli.mjs /usr/local/bin/ok \
 && ln -s /opt/open-knowledge/dist/cli.mjs /usr/local/bin/open-knowledge
COPY --chmod=0755 deploy/entrypoint.sh /usr/local/bin/entrypoint.sh
ENV NODE_ENV=production \
    PORT=8080 \
    OK_BIND=0.0.0.0 \
    HOME=/home/openknowledge
USER ${OK_UID}:${OK_GID}
WORKDIR /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:8080/readyz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
