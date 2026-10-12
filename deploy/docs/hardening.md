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
8. Keep `DO_NOT_TRACK=1`, `DISABLE_TELEMETRY=1`, `OK_DISABLE_LOCAL_SINK=1` and `OTEL_SDK_DISABLED=true`. These switches stop skill-install reports, local diagnostic spans and server logs, and the push of traces and metrics. The image and the Compose file both set them.
9. Set `OK_LOG_LEVEL=warn` and `OK_MCP_AUTOSTART=0`. These settings reduce CLI file logs and prevent an MCP launcher from starting another server.

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

The server keeps its content ownership registry under `.ok/local/` in the home directory of the container user's passwd entry, not in `/data`, so a new container starts with an empty registry.
That user needs a passwd entry and a home directory it can write.
Without either, the server exits with code 1 before `/readyz` answers, and a writable `HOME` path replaces neither.

### Knowledge base: committed configuration

The kit applies these settings to `/data/.ok/config.yml`, which travels with the repository. The entrypoint sets both keys to `false` at each start, before the server starts. You do not add them.

1. `telemetry.localSink.enabled: false` stops local diagnostic spans and logs. The switch `OK_DISABLE_LOCAL_SINK=1` stops them too, before the server reads a file.
2. `lossCapture.enabled: false` stops local records of content-loss events. This path has no environment switch.

```yaml
telemetry:
  localSink:
    enabled: false
lossCapture:
  enabled: false
```

With these defaults a start writes no diagnostic span and no server log: a new data volume holds no file under `.ok/local/telemetry/`, `.ok/local/logs/` or `.ok/local/loss-capture/`.
A data volume from an earlier release gets the keys at its next start. Its old files stay and get no new byte; delete them when your policy requires it.
The entrypoint also writes `telemetry.skillInstallReports.enabled: false` into `.ok/global.yml` in the home directory of the container user, in each new container.
It sets a key back to `false` when a person or the settings page changed it.

The schema marks `lossCapture.enabled` as a setting that needs no restart, but the server reads the key one time, when it starts. A change of the key in the settings page or by a pulled commit therefore changes the file only: the running server keeps the state of its start, and at the next start of the container the entrypoint sets the key to `false` again before the server reads it. If a later release applies the key without a restart, such a change holds until the next start of the container.

#### What the entrypoint changes in a configuration file

The entrypoint writes a file only when a key is absent or not `false`. For each key it uses the first method of this table that gives the result, so that it changes as few bytes as possible.

| Case | Method | What changes in the file |
| --- | --- | --- |
| The file does not hold the top-level key (`telemetry` or `lossCapture`). A new file from `ok init` is this case. | It adds the lines of the key at the end of the file. | No byte before the new lines changes. If the last line has no line end, the program adds one first. The new lines have the line ends of the file: CRLF when the file holds a CRLF, LF in each other file. |
| The key exists with another single value, such as `true` or `"false"`. | It replaces the text of the value with `false`. | Only the bytes of the value. |
| The key is absent, and a mapping above it exists in block style. | It adds the lines of the key at the start of that mapping, before its first key and with the indentation of that key. | No other byte changes. A comment directly above the first key of the mapping is then above the new lines. |
| Each other case: a value above the key is empty, a single value, a list or an alias; the mapping is in flow style; the value has a tag; an alias in another place uses the value; or the file holds only an empty value (`~` or `null`). | The YAML parser writes the whole file again. | The data of each other key, the order of the keys and the comments stay. The layout of the whole file can change: see the list below. |

In the last case only, the parser keeps the data, the order of the keys and the comments, and it does not keep the layout of the file. Tests showed these changes; another detail of the layout can change too:

- Indentation becomes two spaces, and the items of a list are indented.
- Two or more empty lines between keys become one empty line. Spaces at the end of a line go. Two or more spaces between a value and its comment become one.
- A flow mapping or a flow list gets spaces inside its brackets, and stays on one line.
- The lines of one paragraph of a folded text (`>`) go on one line, and a quoted text that covers two or more lines goes on one line.
- A key in the long form (`? key`) gets the short form.
- The parser writes some numbers with another text: `0xFF` becomes `0xff`, `1e3` becomes `1e+3`, and an integer or a fraction that is too long for a 64-bit float loses digits. The program compares the text of each number before and after. When one text differs, it does not use this method, and the key is not set.
- An empty value, a single value or a list above the key becomes a mapping, so that value is lost. A comment inside such a value moves below the new key.
- An alias above the key becomes a copy of the data of its anchor, so the other users of the anchor keep their data. When an alias in another place uses the value of the key, that alias becomes a copy of the earlier data.
- A file with only CRLF line ends keeps them, and a file with a byte order mark keeps the mark. A file that mixes CRLF and LF gets LF in each line.

The program writes a file in one of two ways, and neither way cuts the file before the new content is on disk:

- When each change of the file is an addition at its end, the program opens the file for append and writes the new lines. The file keeps its inode, its owner and its mode. If the write fails, for example on a full disk, the program cuts the file back to its length before, so no part of the new lines stays.
- In each other case, and when the file cannot be opened for append, the program writes a temporary file `<name>.no-telemetry.tmp` next to the file, flushes it to disk and renames it over the file. The file then has a new inode and the container user as its owner, and it keeps its mode. A file without write permission in a directory with write permission is therefore replaced. One file can need both ways, for example a replaced value and an added key; the program then uses this way for the whole file.

When the temporary file cannot be written or the rename is not possible (a full disk, a bind mount of the single file, a directory without write permission), the program does not change the file and prints the reason. It does not write the file in place. A file in a bind mount of the single file, or in a directory without write permission, therefore gets a key only by an addition at its end. The program removes the temporary file after a failure. At each start it also removes a regular file with this exact name that a stopped run left next to a configuration file. When the removal is not possible, the program continues, and an addition at the end of the file still works. Another object with this name (a link, a directory, a FIFO) stays, and so does a regular file that the program cannot remove. Such an object blocks each edit that needs the rename: the program does not change the configuration file and prints the reason. A byte that is not valid UTF-8 stays in the first way and becomes the replacement character U+FFFD in the second.

Not verified: the state of the file after a loss of power during the append. The append is one write of fewer than 100 bytes.

#### Symbolic links

The program follows a symbolic link only when the link leads to a regular file with a name that ends in `.yml` or `.yaml`, inside the same `.ok` directory: `/data/.ok` for the two project files, and the `.ok` directory of the home directory for the user file. It then changes that file and keeps the link. The same rule applies when `/data/.ok/local` is a link. When that link leads to no directory, or to a directory without a `config.yml`, no file exists to change, and the program prints nothing for it.

In each other case the program does not read the target, writes nothing, creates no file and no directory, and keeps the link. It prints one line with the reason, and the telemetry check reports the same file. These are the cases: the link leads out of the `.ok` directory; the target does not exist; the target is not a regular file; the name of the target has another ending; the `.ok` directory itself is a link. The only directory that the program creates is the `.ok` directory of the home directory.

A hard link gives one file a second name, and that name can be outside the `.ok` directory. The program therefore refuses a configuration file that has more than one hard link, with or without a symbolic link before it. It does not read the file and does not write it, prints one line with the reason, and the telemetry check gives the same reason.

Before each write the program parses the new text. It confirms that each telemetry key is `false`, that the data of each other key equals the data before, and that the text of each number is the same. After the write it reads the file again and makes the first two comparisons again. If one is not true, it puts the original bytes back with a temporary file and a rename, and it reports the problem. If that is not possible, the line of the problem starts with `CHANGED` in place of `not changed`.

The entrypoint does not set a key in these cases:

- The YAML parser reports an error for the file: a syntax error, a tab as indentation, a second document, a duplicate key or an alias without an anchor.
- The top level of the file is a list or a single value other than an empty value.
- The file is a symbolic link that the program does not follow, the path is not a regular file, or the file has more than one hard link: see [Symbolic links](#symbolic-links).
- The file cannot be written: a read-only data volume, a full disk, or a file that needs a rename where a rename is not possible.
- No method keeps the data of the other keys and the text of each number.
- The file does not hold the result after the write.

The program decides for each key. It can set one key of a file and refuse another key of the same file. For example, in a file with `telemetry: ~` and a number that the parser writes with another text, `lossCapture.enabled` gets its lines at the end and `telemetry.localSink.enabled` stays unset. The output names each key that is set and each key that is not.

In each of these cases the program prints the reason, the entrypoint prints a line that starts with `[entrypoint] a telemetry setting is not applied`, and the server starts. The environment switches keep the local sink, the skill-install report and the push off. Loss capture has no environment switch, so it uses the value that the server reads from the file, or the upstream default (on), until you correct the file and start the container again.

#### Local records without a switch

The server appends one line to `skill-install-events.jsonl` in the `.ok` directory of the home directory of the container user for each skill install action. These actions write it: `ok init` without `--no-skills`, `ok repair-skills`, `ok cowork`, and the skill install route that the browser calls. No environment variable and no configuration key turns this record off. The entrypoint uses `--no-skills`, so a start writes no such file. `no-telemetry.mjs --check` reports the file when it exists. The home directory is not in the data volume, so a new container does not hold the file.

`scripts/tenant/smoke.sh` checks the result in a started container. `scripts/tenant/telemetry.sh` checks that the kit files keep each switch and do not name the build setting `VITE_OTEL_ENABLED`, and that the upstream source has no new configuration default, environment variable, outbound host or telemetry module. The browser application holds a trace exporter that is on only in a build with `VITE_OTEL_ENABLED=true`; the image build sets no such value, and `deploy/Dockerfile.dockerignore` keeps each `.env` file out of the build.

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

Warning: duplicate YAML keys can invalidate a configuration layer and restore defaults. Merge settings instead of appending them repeatedly. Do not append `telemetry` or `lossCapture` to `/data/.ok/config.yml`: the entrypoint already wrote these keys, and a second top-level key of the same name makes the file invalid.

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
3. Use `ok mcp --port <port>` in the editor entry, with `DO_NOT_TRACK=1`, `DISABLE_TELEMETRY=1`, `OK_DISABLE_LOCAL_SINK=1` and `OTEL_SDK_DISABLED=true` in its environment. Set `<port>` to `OK_PUBLISH_PORT` for an editor on the Docker host. This connects to the container. The four switches stop skill-install reports, local diagnostic spans and logs, and the push of traces from the launcher process on your machine. The form without `--port` uses a local project, not the container. Set `OK_MCP_AUTOSTART=0` if you must prevent that form from starting another server.
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
| Telemetry switches | Applied in `deploy/` | `deploy/compose.yaml` `environment` and the `ENV` instruction of `deploy/Dockerfile` set `DO_NOT_TRACK`, `DISABLE_TELEMETRY` and `OK_DISABLE_LOCAL_SINK` to `1`, and `OTEL_SDK_DISABLED` to `true`. |
| Log and autostart settings | Applied in `deploy/` | `deploy/compose.yaml` `environment` sets `OK_LOG_LEVEL: warn` and `OK_MCP_AUTOSTART: "0"`. |
| Initialization flags | Applied in `deploy/` | `deploy/entrypoint.sh` runs `ok init --no-mcp --no-skills` when `/data/.ok` is absent, then the telemetry program, then `exec ok start`. These flags skip MCP registration and user-global skill bundles, not project-local skills. |
| Committed configuration | Applied in `deploy/` | `deploy/entrypoint.sh` runs `deploy/no-telemetry.mjs` at each start. It sets `telemetry.localSink.enabled` and `lossCapture.enabled` to `false` in `/data/.ok/config.yml`, and `telemetry.skillInstallReports.enabled` to `false` in the user file of the container. |
| Telemetry check | Applied in `deploy/` | `scripts/tenant/smoke.sh` runs `no-telemetry.mjs --check` in the started container. The check reports a switch with another value, a key that is not `false`, a recorded file in the data volume, and the file `skill-install-events.jsonl` in the home directory. `scripts/tenant/telemetry.sh` compares the kit files and the upstream source with `scripts/tenant/telemetry.baseline`. |
| Machine-local configuration | Operator action | Merge the machine-local configuration above into `/data/.ok/local/config.yml`. The kit does not apply these hardening values. |
| Pinned MCP launcher and signature check | Operator action | Apply the launcher checklist on the editor's machine. Use a project-local install for the signature check. |
| Non-root editor and MCP server | Operator action | Configure the editor's machine to run them without root privileges. |
| MCP tool permissions | Operator action | Deny marketplace tools and require approval for document changes in the MCP client. |
| Host skill-install reports | Operator action | Set `telemetry.skillInstallReports.enabled: false` in `~/.ok/global.yml` on the editor's machine. The switches and the entrypoint of the kit cover only the container. |
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
`scripts/tenant/telemetry.sh` fails when the upstream source names a host that `scripts/tenant/telemetry.baseline` does not list, or names a listed host in more or fewer places. Add the host to these tables when you add it to the baseline.

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
| `add-skill.vercel.sh` | Public skill-install reports send skill, source and agent names | Block; keep `DO_NOT_TRACK=1` and `DISABLE_TELEMETRY=1`. The kit also sets the report key to `false`. |
| The host of `OTEL_EXPORTER_OTLP_ENDPOINT` | The push of traces and metrics, only when `OTEL_SDK_DISABLED` is `false` | Block; keep `OTEL_SDK_DISABLED=true`. |
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
