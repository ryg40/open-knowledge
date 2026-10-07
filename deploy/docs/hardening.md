# Harden the OpenKnowledge container

This page lists protections in the container kit and the actions you must take.
The server has no authentication of its own.
Use the [deployment guide](deployment.md) for build, configuration, backup and launcher commands.

## Hardening checklist

The knowledge base is the Markdown repository stored at `/data`.
The Docker host is the machine that runs the container.
An edge server is a reverse proxy that authenticates requests before forwarding them.
Egress is network traffic that leaves the container or browser.
MCP means Model Context Protocol, which lets an AI agent call tools.
ACP means Agent Client Protocol, which starts external AI agent programs.
A skill is a folder of instructions for an AI agent.
An API is an interface that programs use to request data or actions.
CLI means command-line interface, which accepts typed commands.
Transport Layer Security (TLS) encrypts network connections.
HTTP is the protocol for web requests; HTTPS protects HTTP with TLS.
YAML is the format of the configuration files; a schema defines their allowed keys.
Docker Compose creates containers, networks and storage from a YAML file.
A named volume is persistent storage that Docker manages under a chosen name.
A healthcheck is a repeated command that tests whether a container is ready.

### Network

1. Use a dedicated Docker network with only the edge server and OpenKnowledge. Other containers must not reach the unauthenticated server.
2. Publish on `127.0.0.1` only, or remove the port mapping when the edge server uses the Docker network. This address is loopback, which admits connections from the Docker host only. The healthcheck runs inside the container and needs no published port.
3. Require authentication and TLS at the edge server. Prefer single sign-on (SSO) through your identity service. This gate protects only requests that pass through it.
4. Deny container egress by default and allow only approved destinations. The core server needs no external host. Use the [host tables](#network-hosts) for feature rules. Allow established reply traffic before denying new outbound connections.

For an edge-server-only network, add this to an override file outside the repository:

```yaml
services:
  openknowledge:
    ports: !reset []
```

Give both files with `-f` on each Docker Compose command.
The `!reset` form needs Docker Compose 2.24.0 or newer.

Warning: direct server access bypasses the edge server. Trust each host process and each container that can reach the server.

### Container

BuildKit is Docker's image builder; its frontend reads the Dockerfile.
A digest is a hash that identifies exact image content.
SHA-512 is the hash used to check the npm tarball, a compressed package archive.
npm and pnpm are package managers that install JavaScript packages.
Native addons are compiled extensions included in the package.
A bind mount exposes a host directory inside the container.

1. Pin the base image by digest. This prevents a changed tag from selecting another base image.
2. Pin the BuildKit frontend image by digest in the Dockerfile's `# syntax=` instruction. The frontend controls the build.
3. Build from source with the frozen lock file, and check hashes of directly downloaded archives. The lock file fixes dependency versions, and the hashes check archive content. Prefer [build.sh](../../scripts/tenant/build.sh), which exports a Git commit before building.
4. Run as a non-root user that owns `/data`. This limits the files and privileges available to the server.
5. Set `cap_drop: [ALL]` and `security_opt: [no-new-privileges:true]`. Capabilities grant extra Linux privileges; these settings remove them and prevent privilege increases.
6. Set `read_only: true` with writable `/data` and `tmpfs` mounts for `/tmp` and `/home/openknowledge`. A `tmpfs` stores temporary files in memory. These mounts provide the writable locations the server needs. Test your features before enabling this setting.
7. Mount another system's directory with `:ro` unless its owner approves two-way editing. The `:ro` option prevents knowledge base writers from changing those files.
8. Set `DO_NOT_TRACK=1`, `OK_LOG_LEVEL=warn` and `OK_MCP_AUTOSTART=0`. These settings stop skill-install reports, reduce CLI file logs and prevent an MCP launcher from starting another server.

The kit pins the frontend by digest. Inspect the source-selected frontend before updating it:

```sh
frontend=$(sed -n 's/^# syntax=//p' deploy/Dockerfile) &&
  docker buildx imagetools inspect "${frontend:?}"
```

For an update, inspect the intended tag separately. Review its `Digest:` value, then set `# syntax=<frontend tag>@sha256:<digest>`. Update the matching "Release facts" row of `EXPLAINER.md` and run `scripts/tenant/pins.sh`.
For a read-only root filesystem, add this to an override file outside the repository:

```yaml
services:
  openknowledge:
    read_only: true
    tmpfs:
      - /tmp
      - /home/openknowledge:mode=1777
```

The named `/data` volume stays writable.

### Knowledge base: committed configuration

Merge these settings into `/data/.ok/config.yml`, which travels with the repository.

1. Set `telemetry.localSink.enabled: false`. This stops local diagnostic spans and logs after configuration loads.
2. Set `lossCapture.enabled: false`. This stops local records of content-loss events.

```yaml
telemetry:
  localSink:
    enabled: false
lossCapture:
  enabled: false
```

Startup can still write diagnostic spans before these settings load.

### Knowledge base: machine-local configuration

Merge these settings into `/data/.ok/local/config.yml`, which does not travel with the repository.

1. Set `linkPreviews.enabled: false`. This stops external link cards from sending requests to destination sites and GitHub APIs.
2. Set `search.semantic.enabled: false`, or use an approved internal provider through `search.semantic.baseUrl`. Semantic search ranks text by meaning and sends document text and queries to an embeddings provider, which converts text into numbers.
3. Set `autoSync.mode: "off"`. This stops scheduled Git transfers, not manual pull or push.

```yaml
linkPreviews:
  enabled: false
search:
  semantic:
    enabled: false
autoSync:
  mode: "off"
```

`linkPreviews.enabled` works only in `/data/.ok/local/config.yml`, not the committed file.
Use [Configure the knowledge base](deployment.md#configure-the-knowledge-base) to validate both files.

Warning: duplicate YAML keys can invalidate a configuration layer and restore defaults. Merge settings instead of appending them repeatedly.

### MCP client launcher

An MCP client is an editor or agent that calls tools through MCP.
The launcher is the command `ok mcp` that the MCP client starts on your machine, outside the container.
[Pin the host MCP launcher](deployment.md#pin-the-host-mcp-launcher) gives the MCP entry and installation commands.

1. Check the `OK_VERSION` release from [the Dockerfile](../Dockerfile) in a new project directory before installing it globally. Replace `<version>` with that release in these commands. The audit checks registry signatures and package origin records for project dependencies, not global packages.

   ```sh
   npm init -y
   npm install --ignore-scripts "@inkeep/open-knowledge@<version>"
   npm audit signatures
   ```

   Continue only when the audit succeeds and reports verified registry signatures. The `--ignore-scripts` option prevents install scripts during this check only.
2. Install that version with `npm install -g "@inkeep/open-knowledge@<version>"` instead of using an `@latest` launcher. This keeps the executable version fixed between launches.
3. Use `ok mcp --port <port>` in the editor entry, with `DO_NOT_TRACK=1` in its environment. Set `<port>` to `OK_PUBLISH_PORT` for an editor on the Docker host. This connects to the container and disables skill-install reports. The form without `--port` uses a local project, not the container. Set `OK_MCP_AUTOSTART=0` if you must prevent that form from starting another server.
4. Run the editor and MCP server as a non-root user. This limits their host privileges.
5. Deny `mcp__open-knowledge__import`, `mcp__open-knowledge__install` and `mcp__open-knowledge__skills` in the MCP client's permission settings. These tools fetch and install external skills. Keep the server name `open-knowledge` so these tool names match. Require approval for `mcp__open-knowledge__write` and `mcp__open-knowledge__delete`. They change documents or assets.
6. Set `telemetry.skillInstallReports.enabled: false` in your machine's `~/.ok/global.yml`. The server otherwise sends skill names, source repositories and agent lists when it reports a public skill installation.

### Data

The launcher's `~/.ok/logs` directory also holds CLI and MCP logs.
Use an encrypted volume driver from [Docker's volume-plugin documentation](https://docs.docker.com/engine/extend/plugins/#volume-plugins), or encrypt the host storage.

1. Encrypt the data volume and the launcher's `~/.ok` directory. These locations hold documents, logs and configuration that the kit does not encrypt.
2. Include `/data/.git/ok`, Git history and browser site data in your deletion policy. The shadow repository at `/data/.git/ok` records saves, so document deletion does not remove every copy. Purge retained copies when your policy requires complete removal.
3. Back up the volume before upgrades. Use [Back up and roll back](deployment.md#back-up-and-roll-back) to preserve a recovery copy.
4. Keep secrets out of the knowledge base, release repository and image, and use a secret manager.
   The release repository holds `portable` and its `portable-v*` tags.

Warning: purging history removes recovery copies. Check your retention policy and backup before removal.

## State of the files in `deploy/`

"Applied in `deploy/`" means a file declares the protection, not that a running container passed a test.
"Operator action" means you must configure or check it outside the supplied defaults.
The paths below start at the repository root.

| Item | State | File and setting, or required action |
|---|---|---|
| Separate Docker network | Operator action | Compose creates a default project network only. Attach the edge server to it and keep unrelated services out. |
| Loopback publication | Applied in `deploy/` | `deploy/compose.yaml` `ports` defaults `OK_PUBLISH_ADDRESS` to `127.0.0.1`. The file always publishes the port. Remove the mapping for an edge-server-only network. |
| Edge server authentication | Operator action | Configure authentication, TLS and preferably SSO at your edge server. The kit supplies no edge server. |
| Egress allowlist | Operator action | Install firewall or network policy rules from the host tables. |
| Base image digest | Applied in `deploy/` | `deploy/Dockerfile` `ARG NODE_IMAGE` includes `@sha256:`. All Node stages use `FROM ${NODE_IMAGE}`. |
| Frontend image digest | Applied in `deploy/` | The `# syntax=` instruction of `deploy/Dockerfile` includes `@sha256:`. |
| Source build and archive check | Applied in `deploy/` | `deploy/Dockerfile` runs `pnpm install --frozen-lockfile --offline`. Its native stage compares the tarball's SHA-512 with `OK_NPM_INTEGRITY`. The build does not run `npm audit signatures`. |
| Internal package mirror | Operator action | `deploy/Dockerfile` `OK_NPM_TARBALL` names public npm. Adapting npm downloads needs a Dockerfile change; `NODE_IMAGE` changes only the base image. |
| Non-root user and volume owner | Applied in `deploy/` | `deploy/Dockerfile` defaults `OK_UID` and `OK_GID` to `10001`, sets `USER`, and uses `chown` on `/data`. These arguments select user and group IDs. |
| No extra privileges | Applied in `deploy/` | `deploy/compose.yaml` sets `cap_drop: [ALL]` and `security_opt: [no-new-privileges:true]`. |
| Read-only root filesystem | Operator action | Compose sets no `read_only`. `scripts/tenant/smoke.sh` uses `--read-only`, `--tmpfs /tmp` and `--tmpfs /home/openknowledge:mode=1777`, then waits for `/readyz`. This tests readiness, not every feature. |
| No external directory mount | Applied in `deploy/` | `deploy/compose.yaml` `volumes` mounts only `data:/data`. Any added bind mount needs your access decision; prefer `:ro`. |
| Report, log and autostart settings | Applied in `deploy/` | `deploy/compose.yaml` `environment` sets `DO_NOT_TRACK: "1"`, `OK_LOG_LEVEL: warn` and `OK_MCP_AUTOSTART: "0"`. |
| Initialization flags | Applied in `deploy/` | `deploy/entrypoint.sh` runs `ok init --no-mcp --no-skills` when `/data/.ok` is absent, then `exec ok start`. These flags skip MCP registration and user-global skill bundles, not project-local skills. |
| Committed configuration | Operator action | Merge the committed configuration above into `/data/.ok/config.yml`. The kit does not apply these hardening values. |
| Machine-local configuration | Operator action | Merge the machine-local configuration above into `/data/.ok/local/config.yml`. The kit does not apply these hardening values. |
| Pinned MCP launcher and signature check | Operator action | Apply the launcher checklist on the editor's machine. Use a project-local install for the signature check. |
| Non-root editor and MCP server | Operator action | Configure the editor's machine to run them without root privileges. |
| MCP tool permissions | Operator action | Deny marketplace tools and require approval for document changes in the MCP client. |
| Host skill-install reports | Operator action | Set `telemetry.skillInstallReports.enabled: false` in `~/.ok/global.yml`. Compose's `DO_NOT_TRACK` setting covers only the container. |
| Encrypted storage | Operator action | Configure encrypted storage on the Docker host and editor's machine. |
| Retained document copies | Operator action | Define removal rules for the shadow repository, Git history and browser site data. |
| Backup before upgrades | Operator action | Follow the linked backup instructions and test recovery. |
| Secret exclusions and scan | Applied in `deploy/` | `.gitignore` excludes `.env` and `.credentials`. `deploy/Dockerfile.dockerignore` excludes `**/.env*` and `**/.credentials`. `.gitleaks.toml` rules `env-file` and `credentials-file` detect those file paths. The [scan modes](deployment.md#scan-for-secrets) check HEAD, staged changes or a chosen history range, not commit metadata. |
| Secret-scan exemptions | Operator action | Review `.gitleaks.toml` top-level `[[allowlists]]` and rule-local `[[rules.allowlists]]` tables after each dependency merge. Default gitleaks rules also skip some file types. [Promotion](deployment.md#promote-to-portable) checks host patterns independently. |

The [host-rule contract](deployment.md#host-rules) covers maintainer rules; every host rule ID must start with `host-`.
Scanner errors stop the gate, including failed configuration validation, failed archives and missing scanner summaries.
An override of the pinned scanner image prints the selected image.

## Network hosts

The core server needs no external host.
Deny egress by default; a list of named blocks does not cover caller-selected destinations.
Apply separate rules to the build host, the container and the browser.
A redirect can add a destination host.

### Build host

| Host | Purpose | Rule |
|---|---|---|
| `registry.npmjs.org` | The native-addon tarball, pnpm and locked npm dependencies | Allow for the build only. |
| `deb.debian.org` | Debian packages from the pinned base image's package sources | Allow for the build only. These sources use HTTP, not TLS. |
| `registry-1.docker.io`, `auth.docker.io`, Docker Hub image download hosts | The base image and Dockerfile frontend image | Allow image pulls on the build host only. Confirm download and redirect hosts from your build. |

Not verified: the complete build host list, including registry redirects and Docker Hub image download hosts.
An internal base image or mirror can change these destinations.

### Running container

| Host | Purpose and trigger | Rule |
|---|---|---|
| `add-skill.vercel.sh` | Public skill-install reports send skill, source and agent names | Block; keep `DO_NOT_TRACK=1`. |
| `skills.sh`, `www.skills.sh` | Marketplace searches and catalog requests send search text | Block; deny marketplace MCP tools. |
| `api.github.com` | Marketplace search fallback, repository checks and GitHub link cards | Block; disable external link previews. |
| `github.com` | Skill repository clones, publication and ACP runtime downloads | Block; do not publish or run `ok auth login` in the container. |
| `cdn.agentclientprotocol.com` | ACP agent catalog requests | Block; avoid ACP in the container. |
| `nodejs.org` | ACP Node runtime downloads after consent | Block. |
| `registry.npmjs.org` | ACP agent and browser-tool package downloads through `npx`, npm's package runner | Block at runtime. |
| `openknowledge.ai` | CLI uninstall feedback after you answer a survey; generated share links | Block. Generating a share link sends no server upload. |
| `api.openai.com`, or `search.semantic.baseUrl`'s host | Document text and queries when semantic search is enabled | Block unless you approve the provider; prefer an internal server. |
| Caller-selected Git or HTTPS hosts, including `raw.githubusercontent.com` | External skill catalogs and repository downloads on import | Block unless approved; named marketplace blocks alone do not cover these hosts. |
| Hosts of previewed links and declared Git servers | Link metadata and GitHub-compatible link cards; configured Git transfers | Block unless approved. Disable external previews and scheduled sync in the machine-local configuration. |

### Browser and editor

These requests do not pass through the container's egress rules.

| Host | Purpose and trigger | Rule |
|---|---|---|
| `api.github.com` | The browser fetches the star count when Help opens | Block in browser policy if not needed. |
| `openknowledge.ai` | User-triggered browser feedback and subscriptions; generated share links | Block if not needed. Generating a share link sends no server upload. |
| `www.youtube.com`, `www.youtube-nocookie.com`, `player.vimeo.com`, `www.loom.com` | Embedded media in a document | Block unless approved; media can contact additional hosts. |
| Any HTTPS or secure WebSocket host | HTML code-block previews load resources and make requests in the browser | Restrict browser egress separately. A secure WebSocket is a persistent connection protected by TLS. |
| `unpkg.com` | A YAML editor can fetch the configuration schema URL | Block if not needed, or remove the schema directive from your configuration file. OpenKnowledge does not fetch it. |

## Known limits

- The kit adds no server authentication.
- The kit adds no TLS; configure it at the edge server.
- The kit does not encrypt the data volume or create backups.
- The build checks the tarball's SHA-512, not its registry signatures or package origin records.
- The kit installs no egress firewall or MCP client permission policy.
- Not verified: outbound traffic from a running container, a full read-only deployment, or the launcher in an editor.
- Not verified: a build behind TLS inspection or a native `linux/arm64` image.
