# OpenKnowledge portable release: install explainer

This file explains how to install OpenKnowledge in a container from a portable release. It gives each command that you type, in order. It also names each thing on your machine that a command reads, writes or creates.

The installer kit is the two directories `deploy/` and `scripts/tenant/`. [deploy/docs/deployment.md](deploy/docs/deployment.md) is the reference for the kit. This file is the walk-through for a developer who wants to know the footprint and the components.

How to read this file:

- Each step starts with a short part: what you do, the command, and the output to expect.
- Each step has "Drill-down" blocks. Open a block to see each part that the command touches.
- Replace each placeholder of the form `<name>` with your value.
- Run each command from the root directory of the clone, unless the step gives a different directory.

A maintainer updates this file for each portable release. The section "Keep this file current" gives the edits, and the table "Release facts" holds the values of the release.

## Contents

- [What you get](#what-you-get)
- [Terms](#terms)
- [Keep this file current](#keep-this-file-current)
- [Release facts](#release-facts)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Components](#components)
- [Step 1: Check the requirements](#step-1-check-the-requirements)
- [Step 2: Get the source](#step-2-get-the-source)
- [Step 3: Set up the clone](#step-3-set-up-the-clone)
- [Step 4: Scan the source](#step-4-scan-the-source)
- [Step 5: Build the image](#step-5-build-the-image)
- [Step 6: Test the image](#step-6-test-the-image)
- [Step 7: Write the env file](#step-7-write-the-env-file)
- [Step 8: Start the container](#step-8-start-the-container)
- [Step 9: Configure the knowledge base](#step-9-configure-the-knowledge-base)
- [Step 10: Put an edge server in front of the port](#step-10-put-an-edge-server-in-front-of-the-port)
- [Step 11: Connect an MCP client](#step-11-connect-an-mcp-client)
- [Step 12: Upgrade to the next portable release](#step-12-upgrade-to-the-next-portable-release)
- [Step 13: Remove the install](#step-13-remove-the-install)
- [Footprint](#footprint)
- [Maintainer work](#maintainer-work)
- [Where the outputs come from](#where-the-outputs-come-from)

## What you get

After the install, your machine has these parts:

- One container image. The build makes it from the source of the release tag.
- One container. It runs the OpenKnowledge server as a user that is not `root`.
- One Docker volume. It holds the knowledge base: the documents, a Git repository and the settings.
- One published port on the loopback address.

The install does not give you these parts. You supply them:

- Authentication and TLS. The server has no authentication. Step 10 puts a server for TLS and authentication in front of the port. This file calls it the edge server.
- A backup of the volume. A persistent volume is not a backup.

Warning: any process that reaches the published port can read and change all documents.
Use the [hardening checklist](deploy/docs/hardening.md#hardening-checklist) before storing documents or connecting an MCP client.

## Terms

| Term | Meaning |
|---|---|
| Upstream | The public OpenKnowledge repository on GitHub. The source of the product comes from it. |
| Portable release | A commit of the branch `portable` with a tag `portable-vX.Y.Z`. It holds the upstream source and the installer kit. Each release is one snapshot commit on the upstream release commit. |
| Release repository | The Git repository that holds the branch `portable` and the release tags. You clone it. |
| Bundle | One file that holds a Git branch and its tags. It moves a repository to a machine without a network path. |
| Clone | Your local copy of the repository. `<clone>` is its directory. |
| Git hook | A script that Git runs before a commit or before a push |
| Installer kit | The directories `deploy/` and `scripts/tenant/` |
| Scanner | The program gitleaks. It looks for secrets in files and in commits. The scripts run it from a container image. |
| Image | The container image that step 5 builds |
| Base image | The Node.js image that the `native`, `build` and `runtime` stages start from |
| Dockerfile frontend | The BuildKit program that reads `deploy/Dockerfile`. BuildKit gets it as an image. |
| Native addon | A compiled file with the suffix `.node` that the program loads |
| Env file | A file with `NAME=value` lines. Compose reads it for the values of `deploy/compose.yaml`. |
| Project name | The name that Compose puts in front of the names of the container, the network and the volume |
| Data volume | The Docker volume that the container mounts at `/data` |
| Knowledge base | The documents and the settings that the server serves from `/data` |
| Edge server | A server in front of the published port. It does TLS and authentication. A reverse proxy or a gateway can be the edge server. |
| MCP | Model Context Protocol. An AI agent uses it to call the tools of the server. |
| MCP client | A program that speaks MCP, for example an editor with an AI agent |
| Launcher | The command `ok mcp` on your machine. An MCP client starts it and uses its standard input and output. |

## Keep this file current

Do these edits for each new portable release:

1. Update each row of the table "Release facts" from the source that the row names.
2. Update both `RELEASE_TAG=` lines: in "Quick start" and in "Step 2: Get the source".
3. Update the facts before the promotion that carries this file.
4. Do the steps on a test machine. Compare each output block and each drill-down with the result.
   Check the scan modes, hook ranges, host-file contract and promotion checks when the gate scripts change.
5. Update the section "Where the outputs come from". Keep earlier observations distinct from checks of the new release.

Pin literals belong in their single rows in "Release facts" only. Run `scripts/tenant/pins.sh` after updating the table. It lists the pins and their sources, then checks this file and `deploy/docs/*.md` for drift and repeated literals. Exit 0 means agreement, 1 means a doc mismatch, and 2 means the check cannot run. It needs no Docker or Node.js.

The other sections use `RELEASE_TAG`, `UPSTREAM_VERSION` and `IMAGE`, or refer to the table. Output blocks use placeholders for versions. Portable release tags can also appear in the two `RELEASE_TAG=` lines. The native addon count in step 5 comes from the Dockerfile and needs review after an upstream sync. Numeric sample output in step 4 is illustrative, not a release fact.

Port, user ID and project name examples repeat values from the table. Review them in "Quick start", "Components", steps 1, 3, 5 to 13, and "Footprint" when those values change.

## Release facts

| Fact | Value | Source |
|---|---|---|
| Portable release tag | `portable-v0.3.0` | Target release for this file. Not verified: the tag exists. `git tag --list 'portable-v*'` lists available tags. |
| Portable version | `0.3.0` | The release tag without `portable-v` |
| Upstream version | `0.81.4` | `ARG OK_VERSION` in `deploy/Dockerfile` |
| Image tag | `open-knowledge:<upstream version>-p<portable version>` | The "Release identity" format in `deploy/docs/deployment.md`, with this release's versions |
| Base image | `node:24-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20` | `ARG NODE_IMAGE` in `deploy/Dockerfile` |
| Node.js in the base image | `v24.21.0` | `node --version` in the image |
| Earlier observed image | The image of an earlier release with the same upstream version | The observations below predate this release. The smoke checks use that image, not a new pin. |
| Tested tools | Linux `x86_64`, Git `2.39.5`, Docker Engine `29.7.2`, buildx `v0.36.1`, Compose `v5.5.0` | Versions from the earlier observations, not minimum requirements |
| npm used for the signature check | `10.9.8` | The [launcher checklist](deploy/docs/hardening.md#mcp-client-launcher) explains the project-local signature check. |
| Earlier image size | About 434 MB | Docker image inspection of the earlier observed image |
| MCP tool count | 19 | Earlier connection check and `packages/server/src/mcp/tools` |
| Dockerfile frontend image | `docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e` | The `# syntax=` line of `deploy/Dockerfile` |
| Scanner image | `zricethezav/gitleaks:v8.28.0@sha256:cdbb7c955abce02001a9f6c9f602fb195b7fadc1e812065883f695d1eeaba854` | `default_image=` in `scripts/tenant/scan.sh` |
| npm tarball of the native addons | `open-knowledge-<upstream version>.tgz` from `registry.npmjs.org` | Stage `native` of `deploy/Dockerfile` |
| Tarball sha512 | `sha512-ZyS9zwX/wk32z9Kk/YXDO3ebldCQvc3YpVSB9pEpwebcxIkUVZZ+CIhJ3SUWB/Pk1tkJ7rdl3Tm49sBpMXc93Q==` | `ARG OK_NPM_INTEGRITY` in `deploy/Dockerfile` |
| pnpm version | `12.8.1` | `packageManager` in `package.json` |
| Port in the container | `8080` | `PORT` in `deploy/compose.yaml`, `EXPOSE` in `deploy/Dockerfile` |
| Default published address and port | `127.0.0.1:8080` | `OK_PUBLISH_ADDRESS` and `OK_PUBLISH_PORT` in `deploy/compose.yaml` |
| User ID and group ID in the container | `10001` | `ARG OK_UID` and `ARG OK_GID` in `deploy/Dockerfile` |
| Compose project name in the examples | `ok-portable` | This file and `deploy/docs/deployment.md` |

## Requirements

| Tool | Used for |
|---|---|
| Git | The clone. `git archive` exports the source for the build and for the scan. |
| Docker Engine with BuildKit, or Podman 4.8 or newer | The image build, and each container that the scripts start. `deploy/Dockerfile` uses heredoc `RUN` blocks, which need BuildKit or Podman. `OK_CONTAINER_CLI` names the CLI; the default is `docker`. |
| Docker Compose (`docker compose`), or `podman compose` | Creates the container, the network and the volume from `deploy/compose.yaml`. |
| A POSIX shell and standard utilities | `tar`, `sed`, `awk`, `grep`, `od`, `cmp`, `mktemp`, `dirname`, `basename`, `mkdir`, `rm`, `cat`, `sleep`, `date`, `chmod`, `mv`, `cp`, `tr`, `tail`, `xargs` |
| Network access for the build | Step 5 downloads from Docker Hub, `registry.npmjs.org` and `deb.debian.org`. |
| `curl` | Optional. Step 8 uses it for one check. |
| Node.js 24 or newer | The update and workflow checks of the kit refuse an older Node. Step 11 also needs `npm`, for the launcher. |

The image is verified on `linux/amd64` only. The section "Target runtime" of [deploy/docs/deployment.md](deploy/docs/deployment.md) gives the notes for a Mac.

## Quick start

These commands give you a running container with the fewest steps. They skip steps 3, 4, 9, 10 and 11.

1. Get the source and build the image.

   ```sh
   RELEASE_TAG=portable-v0.3.0
   git clone --branch "$RELEASE_TAG" https://github.com/<organization>/<repository>.git open-knowledge
   cd open-knowledge
   UPSTREAM_VERSION=$(awk -F= '/^ARG OK_VERSION=/ { print $2; exit }' deploy/Dockerfile)
   IMAGE=open-knowledge:$UPSTREAM_VERSION-p${RELEASE_TAG#portable-v}
   scripts/tenant/build.sh -t "$IMAGE"
   scripts/tenant/smoke.sh "$IMAGE"
   ```

   The last line of the output must be `smoke: ok <upstream version>`.
2. Make the env file.

   ```sh
   mkdir -p .local/host
   cp deploy/.env.example .local/host/ok.env
   echo "$IMAGE"
   ```

3. Open `.local/host/ok.env` in an editor. Set `OK_IMAGE` to the value that `echo` printed. If port 8080 is in use, set `OK_PUBLISH_PORT` to a free port. `OK_EXTERNAL_URL` keeps the example value. This is enough for loopback access only.
4. Start the container and read its health state.

   ```sh
   docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env up -d --no-build
   docker inspect --format '{{.State.Health.Status}}' ok-portable-openknowledge-1
   ```

   The value must become `healthy`. The server then answers on `http://127.0.0.1:8080/`, or on the port that you set.

Warning: the server has no authentication. Do steps 9 and 10 before you put documents into the knowledge base.

## Components

```text
Build (steps 2 to 6)

  release repository, or a bundle file
        |  git clone at the release tag
        v
  clone on your machine (source tree, deploy/, scripts/tenant/)
        |  scripts/tenant/build.sh: git archive of the commit, plus deploy/
        v
  build context in a temporary directory
        |  docker build with deploy/Dockerfile
        |    stage native   <-- registry.npmjs.org  (npm tarball, sha512 check)
        |    stage build    <-- registry.npmjs.org  (pnpm, packages of pnpm-lock.yaml)
        |    stage runtime  <-- deb.debian.org      (git, ca-certificates)
        |    native/build/runtime <-- Docker Hub    (base image, by digest)
        v
  image open-knowledge:<upstream version>-p<portable version>

Run (steps 7 to 11)

  browser, or MCP client on another machine
        |  HTTPS with authentication
        v
  edge server (yours, not part of the kit)
        |  HTTP and WebSocket
        v
  published port 127.0.0.1:<port> on your machine
        |
        v
  container ok-portable-openknowledge-1, port 8080
     entrypoint.sh -> ok init (first start only) -> ok start
     server process, user 10001: web UI, API, /mcp, /collab, /healthz, /readyz
        |
        v
  volume ok-portable_data at /data (documents, Git repository, .ok/ settings)

  MCP client on your machine
        |  standard input and output
        v
  launcher "ok mcp --port <port>" (npm package on your machine)
        |  HTTP to /mcp, plus a keepalive WebSocket
        v
  published port 127.0.0.1:<port>
```

| Component | What it is | Made in |
|---|---|---|
| Source tree | The clone at the release tag: the upstream source and the installer kit | Step 2 |
| Build context | An export of the commit plus the directory `deploy/`. `build.sh` makes it in a temporary directory and removes it. | Step 5 |
| Build stages | `native`, `build`, `artifacts` and `runtime` in `deploy/Dockerfile`. Only `runtime` becomes the image. | Step 5 |
| Image | The base image plus `git`, the program in `/opt/open-knowledge`, the commands `ok` and `open-knowledge`, and `entrypoint.sh` | Step 5 |
| Container | `<project>-openknowledge-1`. One process tree, user `10001`, no Linux capabilities. | Step 8 |
| Server process | `ok start`. One port serves the web UI, the API, MCP at `/mcp`, the collaboration WebSocket at `/collab`, and the health paths. | Step 8 |
| Data volume | `<project>_data`, mounted at `/data`. Only its content stays when Compose makes the container again. | Step 8 |
| Network | `<project>_default`, a bridge network that only this container uses | Step 8 |
| Published port | `OK_PUBLISH_ADDRESS:OK_PUBLISH_PORT` on your machine, forwarded to port 8080 of the container | Step 8 |
| Edge server | Your server for TLS and authentication. It is not in this repository. | Step 10 |
| Launcher | The npm package `@inkeep/open-knowledge` on your machine, with the command `ok` | Step 11 |
| MCP client | Your editor or agent. Its configuration holds the entry that starts the launcher. | Step 11 |

## Step 1: Check the requirements

Make sure that Git and a container engine are on the machine: Docker with BuildKit and Docker Compose, or Podman with `podman compose`. Each command must print a version. With Podman, set `OK_CONTAINER_CLI=podman` and read `podman` where the commands of this file show `docker`.

```sh
git --version
docker version --format '{{.Server.Version}}'
docker buildx version
docker compose version
```

<details>
<summary>Drill-down: what the install needs from the machine</summary>

Tools that each script calls:

| Script | Tools |
|---|---|
| `scripts/tenant/setup-remotes.sh` | `git`, `sed`, `dirname`; `--check` also calls `install-hooks.sh` |
| `scripts/tenant/install-hooks.sh` | `git`, `grep`, `cmp`, `chmod`, `mv`, `mkdir`, `cat` |
| The `pre-commit` hook | `git`, `public-check.sh` and `scan.sh` |
| The `pre-push` hook | `git`, `cat`, `xargs`, `sort`, `tr` and `scan.sh` |
| `scripts/tenant/scan.sh` | `git`, `tar`, `mktemp`, `docker`, `dirname`, `basename`, `cat`, `awk`, `sed`, `grep`, `od`, `tr`, `rm` |
| `scripts/tenant/build.sh` | `git`, `tar`, `mktemp`, `cp`, `mkdir`, `rm`, `awk`, `grep`, `docker` |
| `scripts/tenant/pins.sh` | `git`, `awk`, `dirname` |
| `scripts/tenant/smoke.sh` | `docker`, `od`, `tr`, `sed`, `grep`, `sleep`, `mktemp`, `tail`, `date`, `rm` |

Network hosts that the install contacts:

| Host | Step | Used for |
|---|---|---|
| The Git server of the release repository | 2, 12 | Clone and fetch. A clone from a bundle contacts no host. |
| The remote URL of a push | The step 3 hook, when you push | Reads current tips with `git ls-remote --refs` |
| Docker Hub. The build log names `registry-1.docker.io`. | 4, 5 | The scanner image, the Dockerfile frontend image and the base image |
| `registry.npmjs.org` | 5 | The npm tarball of the native addons, pnpm, and the packages of `pnpm-lock.yaml` |
| `deb.debian.org` | 5 | The Debian packages `git` and `ca-certificates` |
| `registry.npmjs.org` | 11 | The launcher package for your machine |

Docker downloads an image only when the machine does not have it.

Disk space: see the earlier image size in "Release facts". Not verified: the size of the build cache after a build with an empty cache.

This step changes nothing on the machine.

</details>

## Step 2: Get the source

Clone the release repository at the release tag. The tag gives you one fixed commit of the branch `portable`.

```sh
RELEASE_TAG=portable-v0.3.0
git clone --branch "$RELEASE_TAG" https://github.com/<organization>/<repository>.git open-knowledge
cd open-knowledge
git describe --tags
```

Set `RELEASE_TAG` to the row "Portable release tag" of the table "Release facts". Git prints a note about a "detached HEAD" state. That is correct: the clone is at a tag, not on a branch. The last command prints the release tag.

The later steps use `RELEASE_TAG`, `UPSTREAM_VERSION` and `IMAGE`. In a new shell, set `RELEASE_TAG` again, then repeat the two variable assignments of step 5.

If you have a Git bundle file and no network path to the release repository, clone from the file:

```sh
git clone --branch "$RELEASE_TAG" <bundle> open-knowledge
```

Keep a credential out of the URL. Use the credential store of Git.

<details>
<summary>Drill-down: what the clone creates</summary>

| Item | Content |
|---|---|
| Directory `open-knowledge/` | The working tree of the release commit |
| Directory `open-knowledge/.git/` | The Git objects, the refs and the local Git configuration |
| Remote `origin` | The URL that you gave, or the path of the bundle file |
| Refs | The remote-tracking branch `origin/portable` and the `portable-v*` tags. A bundle can carry more tags. |
| `HEAD` | The commit of the release tag. No local branch exists. |

The clone contacts the Git server of the release repository. A clone from a bundle contacts no host.

The clone does not change the global Git configuration, and it does not use Docker.

`git clone -b portable <bundle> <dir>` gives the newest commit of the branch `portable` in place of a tag. The section "Clone from a bundle" of [deploy/docs/deployment.md](deploy/docs/deployment.md) uses that form.

</details>

## Step 3: Set up the clone

Two scripts prepare the clone for commits and pushes. `setup-remotes.sh` adds the remote `upstream` and disables a push to it. `install-hooks.sh` installs two Git hooks that scan for secrets.

Steps 4 to 9 do not read the remotes or the hooks. Do this step if you commit or push from the clone.

The scripts can read two Git config keys with the names `ok.hostRules` and `ok.historyBase`. An install needs none of them. A non-origin push needs `ok.hostRules` set to an absolute host file or `none`.
The history base matters to history scans and promotion.

```sh
scripts/tenant/setup-remotes.sh
scripts/tenant/install-hooks.sh
scripts/tenant/setup-remotes.sh --check
```

Output of the three commands:

```text
upstream: https://github.com/inkeep/open-knowledge.git (fetch only)
origin: https://github.com/<organization>/<repository>.git
installed: <clone>/.git/hooks/pre-commit
installed: <clone>/.git/hooks/pre-push
ok: pre-commit and pre-push are installed in <clone>/.git/hooks
ok: upstream is fetch-only and origin is set
```

The last line must start with `ok:`.

If `core.hooksPath` is set, `install-hooks.sh` refuses to install and exits with 1. Use `git config --show-origin --get core.hooksPath` to find its source.

Warning: unsetting `core.hooksPath` disables the hooks at that path. `git config --unset core.hooksPath` removes only a local key. Resolve an inherited key at its source before you install again.

After a clone from a bundle, `origin` is the bundle file. Give the release repository in `SHARED_URL`, and the script adds it with the name `github`:

```sh
SHARED_URL=https://github.com/<organization>/<repository>.git scripts/tenant/setup-remotes.sh
```

The output then has one more line:

```text
github: https://github.com/<organization>/<repository>.git (portable and portable-v* tags only)
```

`setup-remotes.sh --check` also prints this line when the remote `github` exists:

```text
ok: github is https://github.com/<organization>/<repository>.git and fetches portable only
```

<details>
<summary>Drill-down: what <code>setup-remotes.sh</code> does</summary>

Without an argument, the script runs the function `setup`:

1. It adds the remote `upstream` with `git remote add` if the remote is absent. `git remote add` does not fetch.
2. It sets four keys. It writes a key only when the value is different.
3. It prints the URL of `upstream` and of `origin`. It removes the user and password part of a URL before it prints the URL.
4. It prints a `warning:` line when `origin` is absent or points to the GitHub upstream.
5. If `SHARED_URL` is set, it runs the function `setup_shared`.

Keys that the script writes into `<clone>/.git/config`:

| Key | Value | Effect |
|---|---|---|
| `remote.upstream.url` | `https://github.com/inkeep/open-knowledge.git`, or the value of the variable `UPSTREAM_URL` | The address for a fetch of the upstream source |
| `remote.upstream.pushurl` | `DISABLED` | Git uses this value as the push address of `upstream`. A push stops with `fatal: 'DISABLED' does not appear to be a git repository`. |
| `remote.upstream.tagOpt` | `--no-tags` | A fetch from `upstream` does not bring the upstream tags. |
| `remote.upstream.fetch` | `+refs/heads/*:refs/remotes/upstream/*` | A fetch brings the upstream branches as `upstream/<branch>`. |

The upstream guard compares lowercase URLs without explicit ports or trailing slashes.
The function `setup_shared` refuses a `SHARED_URL` that points to the GitHub upstream: `refused: SHARED_URL points to the GitHub upstream`, exit 1. If not, it adds the remote `github` and sets these keys:

| Key | Value |
|---|---|
| `remote.github.url` | The value of `SHARED_URL` |
| `remote.github.pushurl` | The value of `SHARED_URL` |
| `remote.github.tagOpt` | `--no-tags` |
| `remote.github.fetch` | `+refs/heads/portable:refs/remotes/github/portable` |

The script reads the environment variables `UPSTREAM_URL` and `SHARED_URL`. It contacts no host. It does not change `origin`, a branch, a tag, the working tree or the global Git configuration.

An install does not fetch from `upstream`. A maintainer fetches from it for an upstream sync.

</details>

<details>
<summary>Drill-down: what <code>install-hooks.sh</code> and the two hooks do</summary>

The hooks directory is `hooks/` in the common Git directory. In a plain clone, that is `<clone>/.git/hooks`. All worktrees of the clone use it.

Without an argument, the script runs the function `install`:

1. It reads `core.hooksPath`. If the key is set, it prints two `refused:` lines and exits with 1. Git ignores the hooks directory when the key is set.
2. It examines the two target files. A hook of the script has the marker line `ok_scan_hook=1`, or the marker line of an older version. If a file exists and has no marker line, the script did not write it. The script then prints `refused: <file> exists and was not written by <script>` and exits with 1.
3. It creates the hooks directory with `mkdir -p`. It writes each hook to `<file>.tmp`, sets mode 755, and moves it to `<file>`.
4. It prints one `installed:` line for each hook.

Files that the script writes:

| File | Runs on | What it does |
|---|---|---|
| `<clone>/.git/hooks/pre-commit` | Each `git commit` | Runs `public-check.sh --staged`, then `scan.sh --staged`. A finding, missing command or check error stops the commit. |
| `<clone>/.git/hooks/pre-push` | Each `git push` | Refuses some pushes, then scans the commits that the remote does not have. |

The `pre-push` hook does these checks:

1. It refuses a push to the remote `upstream`.
2. It refuses a push to a URL of the GitHub upstream.
   The guard compares lowercase URLs without explicit ports or trailing slashes.
3. It stops when `scripts/tenant/scan.sh` is absent or not executable.
4. For a non-origin push, it requires `ok.hostRules` to name an absolute host file or contain `none`.
   It resolves any configured `ok.historyBase` to an upstream commit.
   The base must precede a ref under `refs/remotes/upstream/`.
   Without one, run `scripts/tenant/setup-remotes.sh`, then `git fetch upstream`.
   For a base outside upstream history, choose an upstream ancestor.
   Alternatively, unset the key to scan the whole range; upstream findings can stop the push.
5. It reads remote IDs supplied by Git and current remote tips with `git ls-remote --refs <remote URL>`.
   It uses only IDs that exist locally as commits.
   It never uses remote-tracking refs to exclude remote history. Upstream refs validate the configured base only.
6. For a non-origin push, it admits only `refs/heads/public:refs/heads/portable`, and `refs/tags/portable-v*` under the same name.
   Each pushed tip must be on the public line: every commit outside `refs/remotes/upstream/` carries the release identity, and the tip is `public` or an ancestor of it.
   A pushed `portable-v*` tag must be annotated, and its tagger must be the release identity.
   Without a ref under `refs/remotes/upstream/`, the hook stops and names `git fetch upstream`.
   It refuses a delete or a different source ref name. A configured base must precede each scanned tip.
7. With an ancestor remote commit available locally, it scans `<remote commit>..<local commit>`.
   A rewritten ref uses `<local commit> --not <remote commit>` when its remote commit exists locally.
   Otherwise, it excludes the configured base, remote IDs from push input and locally available advertised tips.
   Without a base, it excludes no upstream refs.
   A failed remote query leaves only the base exclusion and prints one warning.
8. It prints `pre-push: <ref> -> <ref>, <count> commits, range <range>`.
   It runs `scripts/tenant/scan.sh --history <range>`. A finding or scanner error stops the push with exit 1.

Without a base, the hook can scan the whole upstream history. Set an upstream ancestor base.
Fetching upstream does not narrow this scan.
A remote-query failure without a base leaves no exclusions for new refs.
An empty range is valid for a new tag on a commit the remote already has.
If the remote commit is absent locally, the hook treats a rewritten ref as new.

Warning: the `pre-push` hook does not limit the refs for the remote with the name `origin`. In a clone of the release repository, `origin` is the release repository. Push only the public line and its `portable-v*` tags to it, each by name.

A scan starts a container from the scanner image. Docker must run for a commit.
A hook can refuse a push before it scans.
The push hook contacts the remote URL through `git ls-remote --refs`.

`install-hooks.sh` contacts no host. It does not change the Git configuration or a tracked file.

</details>

<details>
<summary>Drill-down: what <code>--check</code> reads</summary>

`setup-remotes.sh --check` changes nothing. It prints a `wrong:` line for each difference and exits with 1.

1. It compares the four `remote.upstream.*` keys with the values that the function `setup` writes.
2. It checks that `origin` exists and does not point to the GitHub upstream.
3. If the remote `github` exists, it checks the four `remote.github.*` keys. With `SHARED_URL` set, the remote must exist and its URL must be equal to it.
4. It runs `install-hooks.sh --check`.

`install-hooks.sh --check` reports a set `core.hooksPath`. For each hook it reports a file that is absent, not written by the script, not executable, or out of date. "Out of date" means that the file is not equal to the hook text in the script.

</details>

<details>
<summary>Drill-down: the two <code>ok.*</code> keys of a maintainer</summary>

An install needs none of these keys. A clone has none of them until someone sets one with `git config`. They are local keys in `<clone>/.git/config`.

| Key | Value | Read by | Without the key |
|---|---|---|---|
| `ok.hostRules` | An absolute host-file path, or `none` for a clone without host rules | `scan.sh`, `public-check.sh`, the `pre-push` hook, `promote.sh` | Tracked-only scans remain possible. Non-origin pushes and promotion stop. |
| `ok.historyBase` | A commit or a ref. The history checks start after it. Any configured base must precede each scanned tip and a ref under `refs/remotes/upstream/`. | `scan.sh --history`, the `pre-push` hook, `promote.sh` | `scan.sh --history` needs a range. The hook excludes no upstream refs. Promotion needs this key for a first push. |

The repository holds no value of a specific deployment and no pattern for one. A maintainer keeps such patterns in a file outside the repository, and `ok.hostRules` names the file.

The section "Host rules" of [deploy/docs/deployment.md](deploy/docs/deployment.md) gives the file format and the four states of the scan.
With `ok.hostRules=none`, the scanner prints one notice and uses tracked rules only. Promotion refuses this value.

</details>

## Step 4: Scan the source

`scan.sh` looks for secrets in the tree of the clone. Run it to see that the scanner works on your machine. The hooks of step 3 use the same script.

```sh
scripts/tenant/scan.sh
```

```text
scan: no host rules, because the Git config key ok.hostRules is not set; the scan uses the rules of .gitleaks.toml only
scan: tree at HEAD
<time> INF scanned ~77246711 bytes (77.25 MB) in 1.4s
<time> INF no leaks found
scan: staged changes
<time> INF 0 commits scanned.
<time> INF scanned ~0 bytes (0) in 36.2ms
<time> INF no leaks found
```

The exit code is 0 when the scan finds nothing, and 1 when it has a finding. The byte counts and the times are different on your machine.

The first line is correct for an install: the key `ok.hostRules` is for a maintainer.

<details>
<summary>Drill-down: what <code>scan.sh</code> does</summary>

The scanner is gitleaks. The script runs it from the scanner image of the table "Release facts". The environment variable `GITLEAKS_IMAGE` selects a different image.
An override prints `scan: scanner image override: <image>`.
A scan without `no leaks found` or `leaks found: <count>` in its output exits with 2.

The rules come from `<clone>/.gitleaks.toml`.
If `ok.hostRules` names a readable, valid host file, the script adds its rules.
It writes both rule sets into `ok-scan-rules.<random>` under `$TMPDIR` or `/tmp` and removes the file on exit.
An absent key or `none` uses tracked rules only, with one notice.
An absent or unreadable file, or a relative path, exits with 2.

The first nonblank, non-comment line of the host file must be `[[rules]]`.
Use unique IDs starting with `host-`, known keys without repeats, single-line values and only `[[rules]]` or `[[rules.allowlists]]` tables.
Each rule needs `regex` or `path`. A host ID cannot replace an ID from the tracked config.
CRLF or BOM input exits with 2 and names the cause. Use UTF-8 without a BOM and LF line endings.
Invalid files exit with 2. Parser refusals name the rule ID or line number and one cause.
An empty file reports `host file has no [[rules]] table`.
Before scanning, gitleaks validates the configuration against an empty directory without network access.
Failed host-rule compilation names its ID but hides the pattern and scanner panic text.
`scripts/tenant/scan.sh --validate-only` validates the configuration without scanning repository content.
See "Host rules" in [deploy/docs/deployment.md](deploy/docs/deployment.md) for supported keys.

Without an argument, the script does two scans:

1. Tree at `HEAD`. The function `scan_head` checks `git archive HEAD` before extracting `ok-scan-archive.<random>` into a temporary directory. The directory is `ok-scan.<random>` under `$TMPDIR` or `/tmp`. Gitleaks scans it in `dir` mode. The script removes the directory. A failed archive or extraction returns 2 without a tree scan.
2. Staged changes. The function `scan_staged` runs gitleaks in `git` mode with `--staged`.

A change that is not committed and not staged is in neither scan.

Each scan is one `docker run --rm --network none`, after the separate configuration validation run.
The script captures output in `ok-scan-log.<random>`, checks the summary, prints the output and removes the file.
The container has these mounts and variables:

| Mount or variable | Content |
|---|---|
| The common Git directory, read-only, at the same path | The Git objects of the clone |
| `<clone>/.gitleaks.toml` or the temporary rules file, read-only, at `/config/gitleaks.toml` | The rules and the allowlists |
| `/work` | The exported tree, read-only, for the tree scan. An empty `tmpfs` for the other modes. |
| `GIT_DIR`, `GIT_WORK_TREE=/work` | Git settings for gitleaks in the container |
| `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=safe.directory`, `GIT_CONFIG_VALUE_0=*` | Sets `safe.directory=*` for Git in the container |
| `GIT_INDEX_FILE`, when set | The alternate index, mounted read-only at the same absolute path for a staged scan |

With `GIT_INDEX_FILE` set, the staged scan prints `scan: staged changes in <index file>`. Git can set this variable for a commit.

Gitleaks runs with `--redact`, so the output shows no secret value.

Other modes:

| Command | What it scans |
|---|---|
| `scripts/tenant/scan.sh --staged` | The staged changes only |
| `scripts/tenant/scan.sh --history "<range>"` | Commits in `A..B` or commit-ID lists with `--not` exclusions. The scanner also accepts `^<commit>` exclusions. Symmetric ranges and other history options are refused. |
| `scripts/tenant/scan.sh --history` | The commits in `<base>..HEAD`. The base is the value of the key `ok.historyBase`. |

Give the whole range as one quoted argument.
`scan.sh --history` without a range and without the key exits with 2.
It prints this message:

```text
scan: --history needs a range, or a history base in the Git config key ok.historyBase
```

Give a range in a clone that has no key.

Exit 2 also reports a wrong argument, missing `.gitleaks.toml`, unresolved range, invalid host rules, non-ancestor base or scanner error.
Other scanner errors remain nonzero.
A configured base must precede each scanned tip and a ref under `refs/remotes/upstream/`, even with an explicit range.
Without an upstream ref, the message gives this remedy:

```text
no ref under refs/remotes/upstream/: run scripts/tenant/setup-remotes.sh, then git fetch upstream
```

For a base outside upstream history, choose an upstream ancestor.
Alternatively, unset the key to scan the whole range; upstream findings can stop the scan.
An `A..B` range also requires `A` to precede `B`.

`.gitleaks.toml` uses the default rules of gitleaks. It adds a rule for a file with the name `.env` and a rule for a file with the name `.credentials`. It also lists the upstream test fixtures that the default rules report. It holds no value of a specific deployment.

Gitleaks defaults skip `gitleaks.toml`, SVG files and lock files.
Promotion checks host patterns independently, including `.gitleaks.toml`, merge-parent diffs and Git-binary files.
The filters use the C locale and treat content as bytes, including invalid UTF-8 and NUL bytes.
NUL-separated tree fields protect output for colon-containing paths. Findings print file, line, commit and rule only.
Paths with tabs or newlines cause a scanner error.
The check matches individual lines, not encoded or compressed content, and reads Git blobs rather than external submodule or large-file storage.

The scan container has no network. Docker contacts Docker Hub only when the machine does not have the scanner image.

The script writes nothing into the clone.

</details>

### Check public content before a commit

The public-content check keeps private text out of fork files.
A fork file differs from the upstream release; an unchanged upstream file stays outside the check.
The command reads `OK_VERSION` from `deploy/Dockerfile` and resolves a matching release tag or `main`.
It verifies the candidate's package version before using its commit.
Missing upstream objects stop the check, rather than silently reducing its scope.

```sh
scripts/tenant/public-check.sh
scripts/tenant/public-check.sh --staged
```

The first command checks complete working files, including new files that Git does not ignore.
The second checks complete staged fork files and reads staged policy and version files.
It respects a temporary `GIT_INDEX_FILE`, so a partial commit checks its own content.
The installed `pre-commit` hook runs the second command before the secret scan.
Reinstall generated hooks only in a clone where you approve that change.

| Class | What it checks |
|---|---|
| `class-1` | Account paths, non-example e-mail addresses, unlisted URL hosts and configured host rules |
| `class-2` | Numbered development references |
| `class-3` | Dated records and session-specific wording |
| `class-4` | Provider, model and agent-program choices |

Generic patterns are in `scripts/tenant/public-check.rules`; no tracked pattern holds a private value.
Host patterns come only from the ignored file named by `ok.hostRules`.
An unset key or `none` uses generic patterns only and prints `host rules: none`.
A configured file must pass the secret scanner's configuration validation and use promotion's supported single-line forms.
The check prints only `file:line class-N`, without matched text.
Exit 0 means clean, exit 1 means findings, and exit 2 means the check cannot run.

Exceptions are in `scripts/tenant/public-check.allow` as exact path, line number, rule ID, line hash and reason fields.
The fields use tabs; the hash covers the full line with one final newline.
A moved or changed line needs a new exception review.
The last field needs a short, non-private reason. A missing reason or a `host-*` rule ID exits with 2.
No whole-file exception exists; explain each exact exception in the commit message too.

`scripts/tenant/public-check.development` lists paths kept only for development.
The content check skips those paths for all four classes and prints each skipped path as `development-only`.
Promotion removes these paths from the snapshot tree and refuses a snapshot that still contains one.
The [public-content reference](deploy/docs/deployment.md#check-public-content) lists admitted hosts, hash construction and scan limits.

Promotion runs `public-check.sh --tree <snapshot commit>` before printing its plan.
It also rejects non-neutral, non-upstream author, committer and release-tag identities on the public line.
The neutral publish identity is `OpenKnowledge Release <noreply@example.com>`. Promotion writes the snapshot commit and the tag with it.
Upstream identities must match exact pairs from the pinned upstream history.
The check covers effective commit and tag identities, not only existing commits.

## Step 5: Build the image

`build.sh` builds the image from the commit of the clone. Set the two variables first. The later steps use them.

```sh
UPSTREAM_VERSION=$(awk -F= '/^ARG OK_VERSION=/ { print $2; exit }' deploy/Dockerfile)
IMAGE=open-knowledge:$UPSTREAM_VERSION-p${RELEASE_TAG#portable-v}
scripts/tenant/build.sh -t "$IMAGE"
```

The build output names the image near its end. Observed with the tools in "Release facts": lines have this form.

```text
#26 writing image sha256:<image ID> done
#26 naming to docker.io/library/open-knowledge:<upstream version>-p<portable version> done
```

Check that the image comes from your commit. The two commands must print the same commit ID.

```sh
docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE"
git rev-parse HEAD
```

<details>
<summary>Drill-down: what <code>build.sh</code> does</summary>

1. It reads the options. `-t <image tag>` is required. `-s <rev>` selects the Git revision, and the default is `HEAD`. Without `-v`, the package version comes from `ARG OK_VERSION` of the copied Dockerfile, or the environment override `OK_VERSION`. An explicit `-v` must equal that upstream version, never the portable version.
2. It resolves the revision to a commit ID.
3. It makes the temporary directory `ok-build.<random>` under `$TMPDIR` or `/tmp`. This directory is the build context. The script removes it when it exits.
4. It exports the commit into the directory with `git archive`. A change that is not committed does not enter the build.
5. It copies the directory `deploy/` of the working tree over the export. A change in `deploy/` that is not committed does enter the build.
6. It runs `docker build` with `deploy/Dockerfile` of the build context and with the image tag.

Build arguments that the script passes:

| Build argument | Source | Effect |
|---|---|---|
| `OK_REVISION` | The commit ID | The label `org.opencontainers.image.revision` |
| `OK_RELEASE_VERSION` | `ARG OK_VERSION` of the copied Dockerfile, or environment `OK_VERSION`. An explicit `-v` must match. | The stage `build` writes the upstream version into the package manifests. |
| `OK_VERSION`, `OK_NPM_INTEGRITY` | Environment variables, if set | Select the npm tarball of the native addons and its sha512 |
| `OK_SOURCE` | Environment variable, if set | The label `org.opencontainers.image.source`. The default is the upstream GitHub URL. |
| `OK_UID`, `OK_GID` | Environment variables, if set | The user and the group of the container |
| `NODE_IMAGE` | Environment variable, if set | Replaces the base image |

`deploy/Dockerfile.dockerignore` limits the build context. It excludes all paths, then admits the source directories and the root manifests. Its last lines exclude these paths, among others: `node_modules`, `dist`, `.git`, `.local`, `.credentials` and each `.env*` file.

The script writes nothing into the clone. It does not push the image.

</details>

<details>
<summary>Drill-down: what each stage of <code>deploy/Dockerfile</code> does</summary>

The stages `native`, `build` and `runtime` start from the base image in "Release facts". They use its digest. The stage `artifacts` starts from `scratch`.

Stage `native` gets the native addons. These are compiled files with the suffix `.node`. The build does not compile them.

1. It downloads `open-knowledge-<upstream version>.tgz` from `registry.npmjs.org` with the Node `fetch` function.
2. It computes the sha512 of the file and compares it with `OK_NPM_INTEGRITY`. On a difference, it prints `integrity mismatch` and the build stops.
3. It extracts `package/dist/native` and copies `index.js`, `index.d.ts` and the `.node` files to `/native/out`.
4. It checks that 8 `.node` files exist, and that `native-config.linux-x64-gnu.node` is one of them.

Stage `build` compiles the program from the source of the clone.

1. It copies `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml` and `patches/`.
2. It installs pnpm with `npm install -g`. The version comes from the field `packageManager` of `package.json`.
3. It runs `pnpm fetch`. pnpm downloads the packages of `pnpm-lock.yaml` from `registry.npmjs.org`.
4. It copies the rest of the build context.
5. It runs `pnpm install --frozen-lockfile --offline`. This command uses no network, and it stops when the lock file does not match the manifests.
6. With `OK_RELEASE_VERSION` set, it writes that version into the `package.json` of the packages `cli`, `core`, `server`, `app` and `desktop`. It also writes it into two `SKILL.md` files.
7. It copies the native addons from the stage `native` into `packages/native-config/`.
8. It builds the package `@inkeep/open-knowledge` and the workspace packages that it needs. It does not build the package of the native addons.
9. It packs the CLI package to `/out`. It installs the CLI package with its production dependencies into `/opt/open-knowledge`.
10. It runs `node /opt/open-knowledge/dist/cli.mjs --version` as a check.

Stage `artifacts` holds the npm tarball and the packed CLI package. `build.sh` gives no target, so the build does not make this stage.

Stage `runtime` is the image.

1. It sets the labels: title, source, revision, version and license.
2. It installs the Debian packages `git` and `ca-certificates` from `deb.debian.org`.
3. It creates the group and the user `openknowledge` with ID `10001`. The home directory is `/home/openknowledge`.
4. It creates `/data` and gives it to that user.
5. It copies `/opt/open-knowledge` from the stage `build`.
6. It links `/usr/local/bin/ok` and `/usr/local/bin/open-knowledge` to `/opt/open-knowledge/dist/cli.mjs`.
7. It copies `deploy/entrypoint.sh` to `/usr/local/bin/entrypoint.sh` with mode 0755.
8. It sets `NODE_ENV=production`, `PORT=8080`, `OK_BIND=0.0.0.0` and `HOME=/home/openknowledge`.
9. It sets the user, the working directory `/data`, the port 8080, the health check and the entrypoint.

</details>

<details>
<summary>Drill-down: what the build downloads and what it verifies</summary>

| Download | From | Check |
|---|---|---|
| Dockerfile frontend image | Docker Hub | The digest in the `# syntax=` line of `deploy/Dockerfile` |
| Base image | Docker Hub | The digest in `ARG NODE_IMAGE` |
| npm tarball of the native addons | `registry.npmjs.org` | The sha512 in `ARG OK_NPM_INTEGRITY`, and the count of 8 `.node` files |
| pnpm | `registry.npmjs.org` | The version comes from `package.json`. The kit pins no hash. |
| The packages of the lock file | `registry.npmjs.org` | `pnpm-lock.yaml` holds the version and an integrity hash of each package. |
| Debian packages `git`, `ca-certificates` | `http://deb.debian.org/debian`, `http://deb.debian.org/debian-security` | apt checks the signed repository metadata. The kit pins no version. The transport is HTTP. |

The program in the image comes from the source of the clone. Only the native addons come from the published npm package.

A second build of the same commit uses the build cache. The frontend digest fixes its content even if the tag changes. BuildKit can still contact Docker Hub for image metadata or missing layers.

A machine behind a proxy that inspects TLS needs more steps. See the section "Build behind TLS inspection" of [deploy/docs/deployment.md](deploy/docs/deployment.md).

Not verified: that no build script of a package contacts a different host. The host list comes from `deploy/Dockerfile` and from the log of one build with an empty cache.

Not verified: the time of a build with an empty cache.

</details>

## Step 6: Test the image

`smoke.sh` starts the image in a test container and waits for the server. It uses its own container and its own volume, and it removes both.

```sh
scripts/tenant/smoke.sh "$IMAGE"
```

```text
smoke: version of open-knowledge:<upstream version>-p<portable version>
smoke: version <upstream version>
smoke: start container ok-smoke-<random>
smoke: wait up to 90s for /readyz
smoke: published on 127.0.0.1:<random port>
smoke: /readyz answered 200
smoke: stop container ok-smoke-<random>
smoke: ok <upstream version>
```

The last line must be `smoke: ok <upstream version>`. Observed with the earlier image in "Release facts": success takes less than one minute.

To read only the version of an image:

```sh
docker run --rm --entrypoint ok "$IMAGE" --version
```

The first line of the output must be the upstream version. The portable version is in the image tag only.

<details>
<summary>Drill-down: what <code>smoke.sh</code> does</summary>

1. It runs `ok --version` in a container with no network. The first line must start with a version number.
2. It creates `ok-smoke-<random>` with `--rm`. It starts the container with attached output in the background.
3. It captures that output in `container.log` under `ok-smoke.<random>` in `$TMPDIR` or `/tmp`.
4. It measures elapsed seconds with `date +%s` and uses a 90-second readiness limit.
   Between checks, it sleeps for at most 2 seconds. Docker operations and cleanup can add time.
   Once the container runs, it prints the port and requests `/readyz` with a 2-second request timeout.
5. Docker selects a free port on `127.0.0.1`. Set `SMOKE_PORT=<free port>` to use a port you checked first. Each request uses another container of the image in the server container's network.
6. On status 200, it removes the container and its volume with `docker rm --force --volumes`.

The version and request containers use the suffixes `-version` and `-probe`, with `--rm`. The exit trap removes remaining containers, their anonymous volumes and the temporary log directory.

Settings of the test container:

| Setting | Value |
|---|---|
| Root file system | Read-only |
| `/data` | An anonymous volume |
| `/tmp` and `/home/openknowledge` | `tmpfs` |
| Capabilities | `--cap-drop ALL`, `no-new-privileges:true` |
| Environment | The 8 variables of `deploy/compose.yaml`, with `OK_EXTERNAL_URL=http://127.0.0.1:8080`. Step 8 lists the variables. |

The exit code is 0 on success, 1 on a failure and 2 on a wrong argument. On a failure, the script prints `smoke: <reason>`. If the container stopped or `/readyz` did not answer, it also prints the last 20 log lines.
The readiness-timeout message gives the measured elapsed seconds and the limit. It removes the container, its volume and the temporary log in each case.

The script does not use Compose. It does not touch the container, the volume or the port of step 8.

</details>

## Step 7: Write the env file

The env file gives Compose the four values that `deploy/compose.yaml` reads. Keep it out of the tracked files: Git ignores the directory `.local/`.

```sh
mkdir -p .local/host
cp deploy/.env.example .local/host/ok.env
echo "$IMAGE"
```

Open `.local/host/ok.env` in an editor and set the values:

| Variable | Set it to | Default in `deploy/compose.yaml` |
|---|---|---|
| `OK_IMAGE` | The value that `echo "$IMAGE"` printed | `open-knowledge:local` |
| `OK_EXTERNAL_URL` | The public URL of the service, for example `https://openknowledge.example.com` | None. Compose stops without it. |
| `OK_PUBLISH_ADDRESS` | Keep `127.0.0.1` | `127.0.0.1` |
| `OK_PUBLISH_PORT` | Keep `8080`, or give a different free port | `8080` |

If port 8080 is in use on the machine, set `OK_PUBLISH_PORT` to a free port.

Warning: an `OK_PUBLISH_ADDRESS` other than a loopback address opens the port to the network. The server has no authentication.

<details>
<summary>Drill-down: what reads the env file</summary>

Only Compose reads the env file. It puts the values into the `${...}` expressions of `deploy/compose.yaml`. `deploy/compose.yaml` has no `env_file` key, so the container does not get the file.

| Variable | Where Compose puts it |
|---|---|
| `OK_IMAGE` | The image of the service |
| `OK_EXTERNAL_URL` | The environment variable `OK_EXTERNAL_URL` of the container |
| `OK_PUBLISH_ADDRESS`, `OK_PUBLISH_PORT` | The published address and port. The port in the container is always 8080. |

Give `--env-file` on every Compose command. Compose then uses the same values for `config`, `up`, `logs` and `down`.

Without `OK_EXTERNAL_URL`, `config` stops. Its message ends with this text:

```text
required variable OK_EXTERNAL_URL is missing a value: set OK_EXTERNAL_URL to the public URL of the service
```

The step creates the directory `.local/host/` and the file `.local/host/ok.env` in the clone. `git status` does not show them. The step uses no network and no Docker object.

</details>

<details>
<summary>Drill-down: an optional override file</summary>

A second Compose file can add values of your machine, for example a bind mount, a network or labels. Put it under `.local/`. Give both files on every Compose command.

Example file `.local/host/compose.host.yaml`:

```yaml
services:
  openknowledge:
    labels:
      com.example.team: docs
```

```sh
docker compose -p ok-portable \
  -f deploy/compose.yaml \
  -f .local/host/compose.host.yaml \
  --env-file .local/host/ok.env \
  config
```

Observed with the tools in "Release facts": `config` shows the label in the service. Not verified: `up` with an override file.

Warning: each container on a network of the service can reach port 8080 with no authentication. Do not attach the service to a shared network without a reason.

</details>

## Step 8: Start the container

Compose creates the container, its network and the data volume. First print the resolved configuration. Then start the service.

```sh
docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env config
docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env up -d --no-build
```

In the output of `config`, check the image, the published port and the volume name `ok-portable_data`. The output of `up` includes these lines, in any order. Compose can also print `Creating` before `Created`.

```text
 Volume ok-portable_data Created
 Network ok-portable_default Created
 Container ok-portable-openknowledge-1 Created
 Container ok-portable-openknowledge-1 Started
```

Read the health state. It must become `healthy`. Observed with the earlier image in "Release facts": this takes about 10 seconds.

```sh
docker inspect --format '{{.State.Health.Status}}' ok-portable-openknowledge-1
```

Optional: request the readiness path from the machine. Give your value of `OK_PUBLISH_PORT`.

```sh
curl http://127.0.0.1:8080/readyz
```

```text
{"ready":true,"status":"ready","degraded":[]}
```

To read the log of the server:

```sh
docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env logs --tail=100
```

Warning: do not give the project name of a different deployment on the machine. Compose then attaches the new service to the volume of that deployment.

Warning: always give `--no-build` to `up`. Without it, `up` builds an image from the working tree when the image of `OK_IMAGE` is absent.

<details>
<summary>Drill-down: what Compose creates</summary>

Compose makes each name from the project name. The examples use `-p ok-portable`.

| Object | Name | Content |
|---|---|---|
| Volume | `ok-portable_data` | Empty at first. The container mounts it at `/data`. |
| Network | `ok-portable_default` | A bridge network. Only this container is on it. |
| Container | `ok-portable-openknowledge-1` | The service `openknowledge` from the image of `OK_IMAGE` |
| Published port | `OK_PUBLISH_ADDRESS:OK_PUBLISH_PORT` | Forwarded to port 8080 of the container |

Compose also adds `com.docker.compose.*` labels to its objects, including the container and the volume.

Settings of the container from `deploy/compose.yaml`:

| Setting | Value | Effect |
|---|---|---|
| `restart` | `unless-stopped` | Docker starts the container again, unless you stopped it. |
| `cap_drop` | `ALL` | The process has no Linux capabilities. |
| `security_opt` | `no-new-privileges:true` | The process cannot get new privileges. |
| `healthcheck` | A request to `/readyz` each 30 seconds | Gives the health state that `docker inspect` shows |
| User | `10001:10001`, from the image | The server does not run as `root`. |

The root file system of the container is writable. The data volume is the only volume.

Environment variables of the container:

| Variable | Value | Effect |
|---|---|---|
| `PORT` | `8080` | The port of the server |
| `OK_BIND` | `0.0.0.0` | The server listens on all addresses of the container. |
| `OK_ALLOW_EXTERNAL` | `1` | The consent to listen on an address that is not loopback. Without it, the server refuses to start. |
| `OK_EXTERNAL_URL` | From the env file | The public origin. The server admits its host name in the `Host` and `Origin` headers. |
| `OK_IDLE_SHUTDOWN` | `off` | The server does not stop when no client is connected. |
| `DO_NOT_TRACK` | `1` | The server sends no skill-install report. |
| `OK_LOG_LEVEL` | `warn` | The file log keeps warnings and errors only. |
| `OK_MCP_AUTOSTART` | `0` | A launcher in the container does not start a second server. |

`up -d --no-build` contacts no host: the image is on the machine. It does not change the clone or the image.

`config` changes nothing. It only prints.

</details>

<details>
<summary>Drill-down: the first start and <code>entrypoint.sh</code></summary>

The entrypoint of the image is `deploy/entrypoint.sh`. It does two things:

1. If the directory `/data/.ok` is absent, it prints one line and runs `ok init --no-mcp --no-skills`.
2. It replaces itself with `ok start`.

On the first start, the log starts with these lines:

```text
[entrypoint] /data is not initialized. Running ok init --no-mcp --no-skills
Initialized git repo at /data/.git/ (default branch: main)
Seeded .gitignore at /data/.gitignore (.DS_Store)
Content scaffolded at /data/.ok/
  Created: .gitignore, config.yml, .okignore
```

`--no-mcp` skips MCP registration. `--no-skills` skips user-global skill bundles, not project-local skills.

The data volume after the first start:

| Path | Content |
|---|---|
| `/data/.git/` | A Git repository with one commit, "Initial commit" |
| `/data/.git/info/exclude` | Local-only exclusions: `.ok/`, `.okignore`, `.mcp.json`, `.cursor/mcp.json`, `.codex/config.toml`, `opencode.json`, `.pi/extensions/open-knowledge.ts`, `.claude/launch.json` |
| `/data/.gitignore` | Ignore rules for files of the operating system |
| `/data/.okignore` | Paths that the document index excludes. Only comment lines at first. |
| `/data/.ok/config.yml` | The project settings. Each key is a comment line at first. |
| `/data/.ok/.gitignore` | Keeps `/data/.ok/local/` out of the Git repository |
| `/data/.ok/local/` | State of this install: `cache/`, `logs/`, `telemetry/`, `principal.json`, `server.lock`, `state.json` |

The initial commit uses the fallback author `Open Knowledge <noreply@openknowledge.local>` when no Git identity exists. The repository does not track `.ok/` or `.okignore`.

User `10001` owns all files. The file `/data/.ok/local/config.yml` does not exist after the first start. Step 9 creates it.

`ok start` then prints a notice and a banner. They have this text:

```text
EXTERNAL ACCESS ENABLED (server.allowExternal) — no server-side authentication.
[...]
open-knowledge v<upstream version>
Local:   http://0.0.0.0:8080
```

The notice is the effect of `OK_ALLOW_EXTERNAL=1`. Step 10 is the answer to it.

The log of a normal start also has `WARN (process-lock)` lines about `/data/.ok/local/server.lock`. Observed with the earlier image in "Release facts": these lines do not prevent a healthy state.

On each later start, `/data/.ok` exists, so the entrypoint runs only `ok start`.

Not verified: that the server contacts no host when it starts.

</details>

## Step 9: Configure the knowledge base

The [knowledge base checklist](deploy/docs/hardening.md#knowledge-base-committed-configuration) explains the settings and their configuration scopes.

Two files in the data volume hold the settings of the knowledge base. Add five settings to turn off diagnostic recording and the listed outbound features. Run each command one time.

Existing files stay, including `/data/.ok/local/telemetry/spans-current.jsonl` and `/data/.ok/local/logs/server-current.jsonl`. Earlier observations show that startup can still write a few kilobytes of spans after this change.

Add the project settings to `/data/.ok/config.yml`:

```sh
docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env \
  exec -T openknowledge tee -a /data/.ok/config.yml > /dev/null <<'EOF'
telemetry:
  localSink:
    enabled: false
lossCapture:
  enabled: false
EOF
```

Add the local settings to `/data/.ok/local/config.yml`:

```sh
docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env \
  exec -T openknowledge tee -a /data/.ok/local/config.yml > /dev/null <<'EOF'
search:
  semantic:
    enabled: false
autoSync:
  mode: off
linkPreviews:
  enabled: false
EOF
```

Check the result:

```sh
docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env \
  exec -T openknowledge ok config validate
```

Read the output, not only the exit code. Both valid configuration and a rejected layer can return exit code 0. The valid result includes this line and no parse error:

```text
✓ Configuration valid (sources: /data/.ok/config.yml, /data/.ok/local/config.yml)
```

Warning: a second run adds duplicate keys. `ok config validate` then prints `Map keys must be unique` and reports issues with a configuration layer. The server drops that layer and can restore defaults, including diagnostic recording.

<details>
<summary>Drill-down: the two files and the five settings</summary>

`tee -a` runs in the container as user `10001`. It adds the lines to the end of the file. It creates the file when the file is absent. The image has no text editor.

| File | Scope | State after the first start |
|---|---|---|
| `/data/.ok/config.yml` | The project. The schema calls this scope `project`. | Exists. Each key is a comment line. |
| `/data/.ok/local/config.yml` | This install only. The schema calls this scope `project-local`. `/data/.ok/.gitignore` excludes the directory `local/`. | Absent |

| Key | File | Default | Effect of the value in this step |
|---|---|---|---|
| `telemetry.localSink.enabled` | Project | `true` | `false`: disables the local diagnostic sink after configuration loads. Startup can still write spans. |
| `lossCapture.enabled` | Project | `true` | `false`: the server records no loss events under `/data/.ok/local/loss-capture/`. |
| `search.semantic.enabled` | Local | `false` | `false`: the search sends no document text to an embeddings provider. |
| `autoSync.mode` | Local | Not set | `off`: the server does no scheduled pull or push of the Git repository. |
| `linkPreviews.enabled` | Local | `true` | `false`: the editor requests no preview of an external link. |

The scope and the default of each key come from `packages/core/src/config/schema.ts`.

The server of the release in the table "Release facts" ignores `linkPreviews.enabled` in the project file. `ok config validate` reports the key there, and names the local file as the correct place.

The schema marks the five keys as `reload: 'live'`. Observed with the earlier image in "Release facts": the span file stops growing after the edit, without a restart.

Not verified: the effect of each of the other four keys on a running server.

This step changes only the two files in the data volume. It contacts no host.

</details>

## Step 10: Put an edge server in front of the port

The server has no authentication. Put an edge server in front of the published port before you use the knowledge base from a different machine. The edge server is yours. This repository holds no configuration for it.

The edge server must do these things:

1. Accept HTTPS for the host name of `OK_EXTERNAL_URL`.
2. Authenticate each request.
3. Forward HTTP requests and WebSocket connections to `OK_PUBLISH_ADDRESS:OK_PUBLISH_PORT`.
4. Send the host name of `OK_EXTERNAL_URL` in the `Host` header.

Warning: the edge server protects only the public host name. Each process on the machine can connect to the published port with no authentication. Each container on the network of the service can connect to port 8080.

Then limit the outbound connections of the container with a firewall or a network policy.
The [network host tables](deploy/docs/hardening.md#network-hosts) separate build, container, browser and editor destinations.

<details>
<summary>Drill-down: what the server admits</summary>

The server examines the `Host` header of each request. Observed with the earlier image in "Release facts": requests to `/` give these results.

| `Host` header for `/` | Result |
|---|---|
| `127.0.0.1:<port>` | Status 200 |
| The host name of `OK_EXTERNAL_URL` | Status 200 |
| The host name of `OK_EXTERNAL_URL`, with `X-Forwarded-For` and `X-Forwarded-Proto` headers | Status 200 |
| A different host name | Status 403, `Host header not allowed.` |
| Any host on `/healthz` or `/readyz`, not `/` | Health paths bypass the host check. `/readyz` answered 200 with a different host name. |

Paths that the edge server forwards:

| Path | Use |
|---|---|
| `/` | The web UI and the API |
| Each path that starts with `/collab` | Collaboration WebSockets: `/collab`, `/collab/thread`, `/collab/keepalive` |
| `/mcp` | MCP over HTTP |
| `/healthz`, `/readyz` | Health and readiness |

Not verified: an edge server or a WebSocket through it. The launcher opens a keepalive WebSocket, as step 11 explains.

</details>

## Step 11: Connect an MCP client

An MCP client starts a launcher on your machine and uses its standard input and output. The launcher is the command `ok mcp` of the npm package `@inkeep/open-knowledge`. Check one fixed version before you install it globally. In a new shell, restore `RELEASE_TAG` from step 2 and the two variable assignments from step 5 first.

Run the signature check in a new project directory:

```sh
UPSTREAM_VERSION=$(awk -F= '/^ARG OK_VERSION=/ { print $2; exit }' deploy/Dockerfile) &&
  mkdir ok-launcher-check && cd ok-launcher-check &&
  npm init -y && npm install --ignore-scripts "@inkeep/open-knowledge@${UPSTREAM_VERSION:?}"
npm audit signatures
cd ..
```

Continue only when the audit succeeds and reports verified registry signatures. Then install that version globally:

```sh
UPSTREAM_VERSION=$(awk -F= '/^ARG OK_VERSION=/ { print $2; exit }' deploy/Dockerfile) &&
  npm install -g "@inkeep/open-knowledge@${UPSTREAM_VERSION:?}"
ok --version
```

Remove `ok-launcher-check` after the check. `--ignore-scripts` prevents package install scripts during the check, not during the global install.

The first line of the output of `ok --version` must be the upstream version.

Then set the MCP entry of your editor. This entry connects the launcher to the published port of the container. Give your value of `OK_PUBLISH_PORT`.

```json
{
  "mcpServers": {
    "open-knowledge": {
      "command": "ok",
      "args": ["mcp", "--port", "8080"],
      "env": {"DO_NOT_TRACK": "1"}
    }
  }
}
```

Keep the server name `open-knowledge`, so that the tool names match. Adapt the outer configuration structure to your editor.

In the permission settings of the MCP client, deny these three tools: `mcp__open-knowledge__import`, `mcp__open-knowledge__install` and `mcp__open-knowledge__skills`.

Not verified: the host install and the editor entry. Earlier observations cover a container install and a connection with the image's `ok` command only.

<details>
<summary>Drill-down: what the launcher does</summary>

`ok init` on a machine can write an MCP entry that runs `npx -y @inkeep/open-knowledge@latest mcp`. That entry downloads the newest release at each launch. The fixed install replaces it.

Observed with a container install: `npm install -g` creates these parts.

| Part | Content |
|---|---|
| `<npm prefix>/lib/node_modules/@inkeep/open-knowledge/` | The package |
| `<npm prefix>/bin/ok`, `<npm prefix>/bin/open-knowledge` | Links to `dist/cli.mjs` of the package |
| The directory from `npm config get cache` | npm package cache and install logs. On Unix, the default is `~/.npm/`. |

The command `npm install -g` contacts `registry.npmjs.org`.

The launcher has two forms:

| Entry | What the launcher does |
|---|---|
| `"args": ["mcp", "--port", "<port>"]` | It forwards MCP messages to `http://127.0.0.1:<port>/mcp`. It also holds a keepalive WebSocket to `ws://127.0.0.1:<port>` and retries when the server is down. |
| `"args": ["mcp"]` | It works on a local project, not the container. On macOS with the Desktop app installed, it can proxy to the app bundle instead. |

Without a bundle proxy, the form without `--port` looks for the project's running server in `.ok/local/server.lock`. If no server runs, it starts `ok start` on your machine. `OK_MCP_AUTOSTART=0` in the entry disables that start. The section "Pin the host MCP launcher" of [deploy/docs/deployment.md](deploy/docs/deployment.md) gives the same two forms.

Observed with the earlier image in "Release facts": `ok mcp --port <port>` prints `[mcp-shim] proxying stdio to http://127.0.0.1:<port>/mcp`. The server answers `initialize` with the name `open-knowledge` and the upstream version. See "Release facts" for the observed tool count.

An MCP client on a different machine cannot use the loopback port. It needs the path `/mcp` behind the edge server of step 10. Not verified: that connection.

`npm audit signatures` examines the installed dependencies of a project directory. With `-g`, it stops with `EAUDITGLOBAL`. Without installed dependencies, it reports `found no installed dependencies to audit`.

The project-local check examines registry signatures and attestations. Observed with the npm version in "Release facts": it reports verified registry signatures and attestations. The [launcher checklist](deploy/docs/hardening.md#mcp-client-launcher) gives this project-local check.

You can also compare the package with the build. This command prints the sha512 that the registry lists for the package:

```sh
npm view "@inkeep/open-knowledge@$UPSTREAM_VERSION" dist.integrity
```

The value must be equal to `ARG OK_NPM_INTEGRITY` in `deploy/Dockerfile`. The stage `native` of step 5 checked the same tarball against that value.

Both `ok --version` and `ok mcp --port` create `~/.ok/logs/cli.<date>.log`. An empty-home check verified this side effect. The [data checklist](deploy/docs/hardening.md#data) covers these logs and their storage.

</details>

## Step 12: Upgrade to the next portable release

An upgrade builds a new image and starts the container from it. The data volume, the env file and the Git configuration stay.

1. Fetch the new release. Set `RELEASE_TAG` to the new tag, and check out the tag.

   ```sh
   git fetch origin
   RELEASE_TAG=<new release tag>
   git checkout "$RELEASE_TAG"
   ```

2. Install the hooks again and run the checks. A new release can change the hook text.

   ```sh
   scripts/tenant/install-hooks.sh
   scripts/tenant/setup-remotes.sh --check
   scripts/tenant/scan.sh
   ```

3. Do step 5 and step 6 again. The variables `UPSTREAM_VERSION` and `IMAGE` get new values. The old image stays for a rollback.
4. Back up the data volume. The section "Back up and roll back" of [deploy/docs/deployment.md](deploy/docs/deployment.md) gives the command.
5. Set `OK_IMAGE` in `.local/host/ok.env` to the new value of `$IMAGE`.
6. Run the `up -d --no-build` command of step 8. Compose makes the container again from the new image.
7. Read the health state as in step 8.
8. If the upstream version changed, do step 11 again with the new version.

Warning: a persistent volume is not a backup. Make the backup before you start the new image.

<details>
<summary>Drill-down: what an upgrade changes</summary>

| Item | Changes | Stays |
|---|---|---|
| Clone | `HEAD` moves to the new tag. `origin/portable` moves. | The Git configuration keys |
| Hook files | Written again. They change only when the hook text changed. | |
| Image | A new image with a new tag | The old image and its tag |
| Container | Compose removes it and creates it again, with the same name. | The network and the published port |
| Data volume | The new server can change files in it. | The volume and its name |
| Env file | The line `OK_IMAGE` | The other three lines |
| Launcher | A new version, when the upstream version changed | The MCP entry |

Facts to update in your records: the release tag, the image tag, the upstream version and the version of the launcher.

`git fetch origin` contacts the Git server of the release repository. Observed with a local source repository: it prints lines of this form.

```text
   <old commit>..<new commit>  portable        -> origin/portable
 * [new tag]             <new release tag> -> <new release tag>
```

A fetch from the remote `github` of step 3 brings no tags, because `remote.github.tagOpt` is `--no-tags`. In a clone that uses that remote, fetch the tag by name: `git fetch github tag <new release tag>`.

The section "Upgrade" of [deploy/docs/deployment.md](deploy/docs/deployment.md) lists the facts that changed in the last upstream sync. The same file gives the rollback steps.

Observed with a temporary volume: the backup command of `deploy/docs/deployment.md` creates `ok-data.tgz`.

Not verified: `up` with a new image tag, and the start of a new image on the data volume of an older image. Earlier observations cover one image only.

</details>

## Step 13: Remove the install

Do these steps in order to take the install off the machine. The table "Footprint" lists each item.

1. Remove the container, the network and the data volume.

   ```sh
   docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env down --volumes
   ```

2. In a new shell, restore `RELEASE_TAG` from step 2. Repeat the two variable assignments of step 5. Remove the image. Do this for each image tag that you built.

   ```sh
   docker image rm "$IMAGE"
   ```

3. Remove the launcher, if you did step 11. Then delete the MCP entry from the configuration of your editor.

   ```sh
   npm uninstall -g @inkeep/open-knowledge
   ```

   Check `~/.ok/logs/` and remove the log files that this launcher created. Check `npm config get cache` for the npm cache and install logs.

   Warning: other OpenKnowledge installs can use `~/.ok/`. Other npm projects share the npm cache. Remove only the files that you no longer need.

4. Remove the configuration of the edge server and the firewall rules of step 10.
5. Go to the parent directory and remove the clone.

   ```sh
   cd ..
   rm -r open-knowledge
   ```

Warning: `down --volumes` deletes the data volume and all documents in it. Make a backup first if you want the documents. Without `--volumes`, `down` keeps the volume.

Warning: `rm -r open-knowledge` also deletes the env file and each backup file that is in the clone.

<details>
<summary>Drill-down: what each removal does, and what stays</summary>

Observed with the Compose version in "Release facts": `down --volumes` prints these lines.

```text
 Container ok-portable-openknowledge-1 Stopped
 Container ok-portable-openknowledge-1 Removed
 Volume ok-portable_data Removed
 Network ok-portable_default Removed
```

`down` without `--volumes` removes the container and the network. `docker volume rm ok-portable_data` then removes the volume.

`docker image rm` removes the tag. It deletes the image layers when no other tag uses them. Observed with Docker in "Release facts": it prints `Untagged:` and the tag.

The removal of the clone takes these items with it: the Git configuration keys, the two hook files, the env file and the override file. All of them are in the directory of the clone.

To keep the clone and remove only the parts of step 3:

```sh
rm .git/hooks/pre-commit .git/hooks/pre-push
git remote remove upstream
```

If you added the release repository with `SHARED_URL`, also run `git remote remove github`.

Not verified: `git remote remove` and `npm uninstall -g`.

These items stay on the machine after the five steps:

| Item | How to remove it |
|---|---|
| The scanner image | `docker image rm` with the scanner image of the table "Release facts" |
| The base image in the image store | `docker image rm <base image>` with the base image from "Release facts" |
| The build cache of BuildKit, with the base image and frontend layers | `docker builder prune` |
| Launcher logs that you keep | Remove the selected files under `~/.ok/logs/`. |
| npm cache and install logs | Inspect the directory from `npm config get cache`. Remove only unneeded files. |
| Backup files outside the clone | Delete the files. |
| Host rules file, if supplied by a maintainer | Remove only unneeded files. Other clones can use them. |

Warning: `docker builder prune` removes the build cache of all projects on the machine, not only of this one.

Not verified: `docker builder prune` and the removal of shared scanner and base images. These resources can belong to other projects too.

</details>

## Footprint

The table lists each thing that exists on the machine after a full install.

| Item | Where | Made in | Removed by |
|---|---|---|---|
| Clone | `open-knowledge/` | Step 2 | `rm -r open-knowledge` |
| Git keys `remote.upstream.url`, `.pushurl`, `.tagOpt`, `.fetch` | `<clone>/.git/config` | Step 3 | `git remote remove upstream`, or the removal of the clone |
| Git keys `remote.github.url`, `.pushurl`, `.tagOpt`, `.fetch`. Only with `SHARED_URL`. | `<clone>/.git/config` | Step 3 | `git remote remove github`, or the removal of the clone |
| Hook files `pre-commit`, `pre-push` | `<clone>/.git/hooks/` | Step 3 | `rm .git/hooks/pre-commit .git/hooks/pre-push`, or the removal of the clone |
| Git keys `ok.hostRules`, `ok.historyBase` | `<clone>/.git/config` | Not made by an install. A maintainer sets them. A non-origin push requires a host file or `none`. | `git config --unset <key>`, or the removal of the clone |
| Host rules file, when supplied | Absolute paths outside the clone | Not made by an install | Remove unneeded files by hand. Removing the clone leaves them. |
| Scanner image | The image store of Docker | Step 4, on the first scan | `docker image rm <scanner image>` |
| Temporary directories `ok-scan.<random>`, `ok-scan-validation.<random>`, `ok-build.<random>`, `ok-smoke.<random>`; files `ok-scan-rules.<random>`, `ok-scan-log.<random>` and `ok-scan-archive.<random>` | `$TMPDIR` or `/tmp` | Steps 4 to 6 | The scripts remove them when they exit. |
| Build cache, with the base image and the frontend image | The build cache of BuildKit | Step 5 | `docker builder prune` |
| Image `open-knowledge:<upstream version>-p<portable version>` | The image store of Docker | Step 5 | `docker image rm "$IMAGE"` |
| Test container `ok-smoke-<random>`, its anonymous volume, and helper containers with `-version` or `-probe` | Docker | Step 6 | `smoke.sh` removes them before it exits. |
| Env file `ok.env`, optional override file | `<clone>/.local/host/` | Step 7 | `rm`, or the removal of the clone |
| Container `ok-portable-openknowledge-1` | Docker | Step 8 | `down` |
| Network `ok-portable_default` | Docker | Step 8 | `down` |
| Data volume `ok-portable_data` | Docker | Step 8 | `down --volumes`, or `docker volume rm ok-portable_data` |
| Published port `OK_PUBLISH_ADDRESS:OK_PUBLISH_PORT` | The machine | Step 8 | `down` |
| Settings in `/data/.ok/config.yml` and `/data/.ok/local/config.yml` | The data volume | Step 9 | Goes with the data volume |
| Configuration of the edge server, firewall rules | Your edge server and firewall | Step 10 | By hand |
| npm package `@inkeep/open-knowledge`, commands `ok` and `open-knowledge` | The global npm directory of the machine | Step 11 | `npm uninstall -g @inkeep/open-knowledge` |
| Launcher logs `cli.<date>.log` | `~/.ok/logs/` | Step 11 | Remove selected log files in step 13. |
| npm cache and install logs | The directory from `npm config get cache`, normally `~/.npm/` | Step 11 | Inspect and remove unneeded files in step 13. |
| Scratch directory `ok-launcher-check`, if you did the signature check | The directory where you made it | Step 11 | `rm -r ok-launcher-check` |
| MCP entry | The configuration of your editor | Step 11 | By hand |
| Backup file `ok-data.tgz` | The directory that you gave | Step 12 | Delete the file. |
| Base image in the image store | The image store of Docker | Step 5. Step 12 also uses it for the backup. | `docker image rm <base image>` |

The install writes nothing to the global Git configuration.

## Maintainer work

These two tasks are not part of an install. A maintainer of the portable branch does them.

### Promotion

`scripts/tenant/promote.sh` makes a portable release in the snapshot mode, the one promotion mode of the repository. It writes one snapshot commit on the local branch `public`, writes the tag `portable-vX.Y.Z`, and pushes the two refs. Without the option `--push`, it is a dry run that changes no ref.

The tree of the snapshot commit is the tree of the development branch without the development-only paths.
Its parents are the earlier release commit, when one exists, and the upstream release commit of the version.
The commit and the tag carry the neutral identity `OpenKnowledge Release <noreply@example.com>`.

| Remote | Branch of the public line there | Refspec |
|---|---|---|
| `github`, the release repository | `portable` | `refs/heads/public:refs/heads/portable` |
| `origin`, a development repository | `public` | `refs/heads/public:refs/heads/public` |

The proof of each release is the output of `git rev-list <snapshot commit> --not <upstream release commit>`.
Promotion prints it and requires that it lists release commits of the public line only. The first release lists one commit.
You can repeat the proof in a clone of the release repository, after `git fetch upstream`.

Before the push, promotion runs the secret scans, host rules and public-content check on the snapshot commit.
Promotion needs a real host file in `ok.hostRules`, and `--visibility` for a push. An install needs neither.
Promotion refuses `ok.hostRules=none`. Fix findings on the development branch, then promote again.
No option bypasses a finding.
A configured `ok.historyBase` must precede the upstream release commit. A first push to a remote needs the key.
Promotion compiles the content and path patterns with PCRE, and gitleaks validates the merged configuration before the scan.
Use patterns supported by both engines. A compilation failure names the rule ID and exits with 2 without printing the pattern.
A missing upstream ref requires `scripts/tenant/setup-remotes.sh`, then `git fetch upstream`, not an unset history base.
Every remote read uses the push URL. The scanner image override prints the selected image.
A remote branch that is not a release commit of the public line stops the run. Promotion never forces a push.

See the sections "Host rules" and "Promote to portable" of [deploy/docs/deployment.md](deploy/docs/deployment.md).

### Continuous integration

The workflow `.github/workflows/portable-release.yml` runs on a tag `portable-vX.Y.Z`. It runs the scripts of steps 4, 5 and 6, pushes the image to a registry, and records the digest. The job runs only when the repository variable `OK_REGISTRY` is set.

See [deploy/docs/ci.md](deploy/docs/ci.md).

## Where the outputs come from

The outputs come from earlier observations with the image and tools named in "Release facts".
The smoke script also passed success, stopped-container and readiness-timeout checks after its log handling changed.
The gate descriptions use the current scripts. Earlier hook observations do not verify the current range behavior.

Not verified: a full installation from the new release tag. Update the observations when that release exists.

| Step | Source of the outputs and of the drill-down |
|---|---|
| 1 | Run |
| 2 | Run, with a bundle file and with a local repository in place of the release repository. Not verified: a clone over HTTPS. |
| 3 | Run, with and without `SHARED_URL`. The refusal for `core.hooksPath` and for the upstream URL: run. The push to `upstream` and the ranges of the `pre-push` hook: run with a local repository as the remote. |
| 4 | Run, with no `ok.*` key. The states with the key `ok.hostRules`: run. |
| 5 | Run, with a full build cache. The stage list: read from `deploy/Dockerfile`. The download hosts: read from `deploy/Dockerfile` and from the log of an earlier build with an empty cache. |
| 6 | Run |
| 7 | Run. The override file: `config` only. |
| 8 | Run, with the project name and the port of the test. The content of the data volume: read from the test volume. |
| 9 | Run. The scopes and the defaults: read from `packages/core/src/config/schema.ts`. |
| 10 | The `Host` header results: run. The paths: read from `packages/server/src`. The edge server: not run. The host lists: linked from `deploy/docs/hardening.md`. |
| 11 | The package install and `npm audit signatures`, with `-g` and in a scratch directory: run in a container. The connection with `--port`: run with the `ok` command of the image. The launcher forms: read from `packages/cli/src/commands/mcp.ts` and `packages/cli/src/mcp/`. The install on a machine and the editor entry: not run. |
| 12 | `git fetch`, `git checkout`, the hooks and the backup command: run, with a local repository in place of the release repository. The start of a new image on older data: not run. |
| 13 | `down --volumes`, `down`, `docker volume rm`, `docker image rm`, the removal of the hook files and of the clone: run. `git remote remove`, `npm uninstall -g` and `docker builder prune`: not run. |
