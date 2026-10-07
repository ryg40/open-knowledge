# OpenKnowledge container deployment

This guide builds and runs OpenKnowledge in a container from this repository. The generic files are in `deploy/` and `scripts/tenant/`. Values of a specific host go in files outside the repository or under an ignored path.

[EXPLAINER.md](../../EXPLAINER.md) is the install walk-through for a developer. It gives each command in order, and it names each thing that a command changes on the machine.

## Files

| File | Purpose |
|---|---|
| `deploy/Dockerfile` | Builds the image from source. It pins the base image by digest and checks the sha512 of the npm tarball. |
| `deploy/compose.yaml` | Runs one service with a named volume at `/data`. |
| `deploy/.env.example` | Lists the variables of `deploy/compose.yaml` with placeholder values. |
| `deploy/entrypoint.sh` | Initializes `/data` on the first start, then starts the server. |
| `scripts/tenant/build.sh` | Builds the image from a Git revision. |
| `scripts/tenant/pins.sh` | Lists the pins and their sources, and checks the docs for drift. |
| `scripts/tenant/setup-remotes.sh` | Makes `upstream` a fetch-only remote. Creates the release remote `github` when `SHARED_URL` is set. |
| `scripts/tenant/scan.sh` | Scans the repository for secrets. It also applies your host rules when you give them. |
| `scripts/tenant/public-check.sh` | Checks fork files for private content and checks publication identities. |
| `scripts/tenant/public-check.rules`, `scripts/tenant/public-check.allow` | Generic content patterns and exact-place exceptions. |
| `scripts/tenant/install-hooks.sh` | Installs the `pre-commit` and `pre-push` hooks. |
| `scripts/tenant/promote.sh` | Writes one snapshot release of `local-dev` on the branch `public`, tags it and pushes the two refs to a remote. |
| `.gitleaks.toml` | Configures the secret scan. It holds no value of a specific host. |

## Remotes

| Remote | Repository | What it receives |
|---|---|---|
| `upstream` | The public GitHub repository of OpenKnowledge. | Nothing. The push URL is `DISABLED`, and the `pre-push` hook refuses a push. |
| `origin` | Your development repository. It is optional. | Each ref that you push by name. The `pre-push` hook does not limit the refs for `origin`. |
| `github` | The release repository. | Only the public line: the local branch `public` as `portable`, and the `portable-v*` tags of that line. |

The public line has one branch name for each place:

| Place | Branch of the public line | Refspec of promotion |
|---|---|---|
| Your clone | `public` | Promotion writes it. It is never checked out. |
| `github`, and each other remote that is not `origin` | `portable` | `refs/heads/public:refs/heads/portable` |
| `origin` | `public` | `refs/heads/public:refs/heads/public` |

A reader of the release repository sees the branch `portable`.
A development repository can also hold a branch `portable` from the earlier merge mode, with its own `portable-v*` tags.
Promotion never moves that branch and never pushes it or its tags.

Development branches and the upstream tags never go to `github`. The `pre-push` hook refuses each other ref for every remote that is not `origin`.
A non-origin push also requires `ok.hostRules` to name an absolute host file or contain `none`.

Warning: in a clone of the release repository, `origin` is the release repository, and the hook does not limit the refs for it. Push only the public line and its `portable-v*` tags to it, each by name.

`setup-remotes.sh` creates `github` when the environment variable `SHARED_URL` is set:

```sh
SHARED_URL=https://github.com/<organization>/<repository>.git scripts/tenant/setup-remotes.sh
```

The script writes this configuration:

| Key | Value |
|---|---|
| `remote.github.url` | The value of `SHARED_URL` |
| `remote.github.pushurl` | The value of `SHARED_URL` |
| `remote.github.tagOpt` | `--no-tags` |
| `remote.github.fetch` | `+refs/heads/portable:refs/remotes/github/portable` |

The script refuses a `SHARED_URL` that points to the GitHub upstream. It prints each URL without the user and password part. Keep a credential out of the URL. Use the Git credential store or `gh auth login`.

Warning: do not push to `github` with `--all`, `--tags`, `--follow-tags` or `--mirror`. `--tags` and `--follow-tags` send upstream tags, and `--all` sends each local branch. Push each ref by name.

## Set up the clone

1. Run `scripts/tenant/setup-remotes.sh`. The script sets `upstream` to the GitHub repository and disables push to it. Set `SHARED_URL` to also create `github`.
2. Run `scripts/tenant/install-hooks.sh`. The script writes `pre-commit` and `pre-push` into the hooks directory of the common Git directory, so all worktrees use them.
3. Run `scripts/tenant/setup-remotes.sh --check`. The script checks `upstream`, `origin`, `github` when it exists, and the hooks through `install-hooks.sh --check`. The last line must start with `ok:`.

The script does not overwrite a hook that it did not write. Move that hook away first, or merge it by hand.

A new version of `install-hooks.sh` can change the text of the hooks. `--check` then reports `out of date`. Run `install-hooks.sh` again. It replaces the hooks that it wrote, also the hooks of an older version.

`install-hooks.sh` refuses to install when `core.hooksPath` is set, because Git then ignores the hooks directory. The script exits with 1, names the path and writes nothing. Run `git config --unset core.hooksPath`, then install again.

Warning: the repository has no `.husky/` directory now. If an upstream sync adds `.husky/`, `pnpm install` can set `core.hooksPath`. Git then ignores the hooks of `install-hooks.sh`. Run `scripts/tenant/install-hooks.sh --check` after each upstream sync. It reports a set `core.hooksPath`.

## Scan for secrets

`scan.sh` runs gitleaks from an image that is pinned by digest.
A different `GITLEAKS_IMAGE` prints `scan: scanner image override: <image>`.
Promotion also prints `promote: scanner image override: <image>` for an override.
A scan without `no leaks found` or `leaks found: <count>` in its output exits with 2. The container has no network, and it mounts the Git directory read-only. The output redacts each secret value.
A failed `git archive` or extraction stops the tree scan with exit 2. No partial tree passes.
Before scanning, gitleaks validates the configuration against an empty directory without network access.
A failed host-rule compilation names its ID, hides the pattern and scanner panic text, and exits with 2.
`scripts/tenant/scan.sh --validate-only` performs this validation without scanning repository content.

| Command | What it scans |
|---|---|
| `scripts/tenant/scan.sh` | The tree at `HEAD` and the staged changes |
| `scripts/tenant/scan.sh --staged` | The staged changes only. The `pre-commit` hook uses this mode. When Git sets `GIT_INDEX_FILE`, the scan reads that index, so `git commit -- <path>`, `git commit -i` and `git commit -o` are scanned too. |
| `scripts/tenant/scan.sh --history` | The commits in `<base>..HEAD`. The base is the value of the Git config key `ok.historyBase`. Without the key, the command exits with 2 and names the key. |
| `scripts/tenant/scan.sh --history "<range>"` | The commits in `<range>`. Use `A..B` or commit IDs followed by `--not` and excluded IDs. The scanner also accepts `^<commit>` exclusions. Symmetric ranges and other history options are refused. The `pre-push` hook uses this mode. |

Exit 0 means no finding. Exit 1 means a finding. Exit 2 means invalid input or a scanner error.
Other scanner errors remain nonzero.
Invalid input includes invalid host rules, an unresolved range, a non-ancestor base or a base outside upstream history.
Give the whole range as one quoted argument.

`.gitleaks.toml` uses the default rules of gitleaks. It adds a rule for a `.credentials` file and a rule for a `.env` file. It also lists the upstream test fixtures that the default rules report. When an upstream sync adds a new fixture, the scan fails. Examine the finding before you add the file to the allowlist.

`.gitleaks.toml` holds no value of a specific host. The section "Host rules" says how the scan gets such values.

The `pre-push` hook refuses a push to `upstream` and to the GitHub upstream URL.
A non-origin push requires `ok.hostRules` to name an absolute host file or contain `none`.
It admits only two refspecs for those remotes: `refs/heads/public:refs/heads/portable`, and `refs/tags/portable-v*` under the same name.
Each pushed tip must be on the public line. Every commit of the tip outside `refs/remotes/upstream/` must carry the release identity, and the tip must be `public` or an ancestor of it.
A pushed `portable-v*` tag must be an annotated tag on a commit, and its tagger must be the release identity. The hook refuses a lightweight tag, and it names the tagger that it found.
Without a ref under `refs/remotes/upstream/`, the hook stops and names `scripts/tenant/setup-remotes.sh` and `git fetch upstream`.
So the hook refuses `local-dev`, a `portable` branch of the earlier merge mode, and each tag of that chain.
It refuses a delete or a different source ref name for those remotes.
The hook prints the refs, commit count and range for each scan:

| Case | Range |
|---|---|
| The remote commit exists locally and precedes the local commit | `<remote commit>..<local commit>` |
| The remote commit exists locally but does not precede the local commit | `<local commit> --not <remote commit>` |
| The remote commit is absent locally, and `ok.historyBase` is set | Commits outside the base, remote IDs supplied by Git for this push, and locally available tips currently advertised by the remote URL. |
| The remote commit is absent locally, and `ok.historyBase` is not set | Commits outside remote IDs supplied by Git and locally available tips currently advertised by the remote URL. No upstream refs are excluded. |

A new ref has no remote commit, so it uses one of the remote-commit-absent cases.
The hook reads current tips with `git ls-remote --refs <remote URL>`.
It never uses remote-tracking refs to exclude remote history. Upstream refs validate the configured base only.
It excludes only remote IDs that exist locally as commits.
When you push `public` with a new tag, the tag scan excludes the remote's existing, locally available tips.
The update of the remote branch uses its own remote commit as the range start.
The hook does not exclude newly pushed local tips. Both ranges can scan the same new commit.
Each scanned tip must descend from the configured base.
The base must also precede a ref under `refs/remotes/upstream/`.
Without such a ref, the hook prints:

```text
no ref under refs/remotes/upstream/: run scripts/tenant/setup-remotes.sh, then git fetch upstream
```

For a base outside upstream history, choose an upstream ancestor.
Alternatively, unset the key to scan the whole range; upstream findings can then stop the push.
A rewritten ref uses `<local commit> --not <remote commit>` when its remote commit exists locally.
If that commit is absent locally, the hook treats the ref as new.

Without `ok.historyBase`, a new ref can scan upstream history. Set an ancestor base.
Fetching upstream does not shorten the range.
If `ls-remote` fails, the hook prints one warning and scans new refs from the base without other exclusions.
Without a base, that failure leaves no exclusions for new refs.
An empty range is valid for a new tag on a commit the remote already has.
A finding or scanner error stops the push with exit 1.

The allowlist paths in `.gitleaks.toml` start with `^`. They match the path from the repository root only, so a copy of a fixture under another directory is scanned. `scan.sh` runs gitleaks in `/work` with the source `.`, so both scan modes report paths from the repository root.

## Check public content

Run `scripts/tenant/public-check.sh` before committing changes to the installer kit.
The command checks complete fork files, not only changed lines.
A fork file differs from the upstream release commit; unchanged upstream files stay outside the check.
The command reads `OK_VERSION` from `deploy/Dockerfile` and tries matching release tags, then `main`.
Each candidate must declare that version in `packages/cli/package.json`.
A missing upstream commit stops the check; it never treats the entire source as fork content.

| Command | Content checked |
|---|---|
| `scripts/tenant/public-check.sh` | Working files, including new files that Git does not ignore |
| `scripts/tenant/public-check.sh --staged` | Complete staged fork files; unstaged changes do not affect content, policy or the version pin |
| `scripts/tenant/public-check.sh --tree <rev>` | Fork blobs and policy files from the selected Git commit |
| `scripts/tenant/public-check.sh --development-only <rev>` | Lists development-only paths present in the complete selected release tree |
| `scripts/tenant/public-check.sh --identities <source> <portable>` | Publication identities in both histories and their reachable release tags |

The installed `pre-commit` hook runs the staged check before the secret scan.
It respects `GIT_INDEX_FILE`, including the temporary index of a partial commit.
Reinstall the generated hooks in an approved clone after updating `install-hooks.sh`.
Promotion checks its snapshot commit before printing the plan.
A finding or an error stops promotion; no option bypasses it.

| Class | Generic patterns |
|---|---|
| `class-1` | Account paths, non-example e-mail addresses, unlisted URL hosts and configured host rules |
| `class-2` | Numbered development references |
| `class-3` | Dated records and session-specific wording |
| `class-4` | Provider, model and agent-program choices |

The generic patterns are in `scripts/tenant/public-check.rules` as tab-separated class, rule ID and PCRE pattern fields.
PCRE means Perl-compatible regular expressions; Git and `grep` must support them for the kit's content filters.
The host list admits GitHub, Docker documentation, npm, Debian, Node.js, loopback addresses and example domains.
A public host outside this short list needs an exact-place exception, not a whole-file exemption.
Host-specific values and patterns belong only in the ignored file named by `ok.hostRules`.
An unset key or `none` uses generic patterns only and prints `host rules: none`.
A configured file must pass `scan.sh --validate-only` and use the single-line forms required by promotion.
Path-only host rules flag matching fork paths; content rules check every matching line.
Host-rule allowlists do not exempt this check. The tracked exact-place list rejects every `host-*` rule ID.
A malformed rule, missing file or failed filter exits with 2 without printing private patterns.

A finding prints only `file:line class-N`, never matched content.
Exit 0 means clean, exit 1 means findings, and exit 2 means the check cannot run.
The filters read bytes, including NUL and invalid UTF-8; paths with tabs, newlines, carriage returns or escape bytes stop the check.
Deleted files have no content to check.
Changed submodules stop the check; unchanged upstream submodules remain outside its scope.
Encoded or compressed values need a separate review.

Each line of `scripts/tenant/public-check.allow` has five tab-separated fields: exact path, line number, rule ID, line hash and reason.
The hash comes from `git hash-object --stdin` with the complete line and one final newline.
A changed line, moved exception or different rule therefore needs a new review.
No path glob or whole-file exception is accepted.
The last field must contain a short, non-private reason. A missing or empty reason exits with 2 and names the row.
Keep the reason in the commit message too, not in a code comment.

`scripts/tenant/public-check.development` lists exact files or directory prefixes ending in `/`, one path per line.
The list includes `docs/agents/`; those documents describe development, not the public product.
The content check skips these paths for all four classes and prints each skipped path as `development-only`.
No exact-place exception may admit a development-only path.
The dedicated `--development-only` check reads every release path, including unchanged upstream paths, and exits with 1 when any matches.
Promotion removes these paths from the snapshot tree. It then runs the dedicated check on the snapshot commit and refuses a snapshot that still contains one.
The same rule applies to `--visibility public` and `--visibility private`.

Promotion also checks every non-upstream author, committer and reachable release-tag identity of the public line.
It checks the effective author and committer for the snapshot commit and tag too.
An identity must exactly match an author or committer in the pinned upstream history, or the neutral publish identity.
The neutral identity is `OpenKnowledge Release <noreply@example.com>`.
`promote.sh` sets the Git author and committer variables to this identity itself. Your own Git identity does not reach the snapshot commit or the tag.
Identity findings print object IDs and roles, not rejected names or addresses.
Upstream identities remain public; accepted upstream pairs cannot approve a different name or address.
The public line holds no commit of the fork development history, so no identity of that history leaves.

## Host rules

A deployment has values that must not enter a tracked file: a domain, a private path, a port, a network name, or wording about one machine. The repository holds no such value and no pattern for one. You give the patterns in a file outside the repository. The file has the rule format of gitleaks:

```toml
[[rules]]
id = "host-value-domain"
description = "Domain of the deployment"
regex = '''(?i)internal\.example\.net'''
keywords = ["internal.example"]

[[rules]]
id = "host-wording-machine"
description = "Wording about one machine"
regex = '''(?i)our build server'''
path = '''^(?:deploy/|scripts/tenant/)'''
```

Give the absolute path of the file in the local Git config key `ok.hostRules`:

```sh
git config ok.hostRules /absolute/path/to/host-rules.toml
```

The scripts and hooks read two local Git config keys. An install needs none of them.
A non-origin push needs `ok.hostRules` set to an absolute host file or `none`.

| Key | Value | Read by |
|---|---|---|
| `ok.hostRules` | An absolute host-file path, or `none` for a clone without host rules | `scan.sh`, `public-check.sh`, the `pre-push` hook, `promote.sh` |
| `ok.historyBase` | A commit or a ref. The history checks start after it. The configured base must precede each scanned tip and a ref under `refs/remotes/upstream/`. | `scan.sh --history`, the `pre-push` hook, `promote.sh` |

`scan.sh` has four states for `ok.hostRules`:

| State | What the scan does |
|---|---|
| The key is not set | It uses the rules of `.gitleaks.toml` only, with one notice. A CI job is in this state. The non-origin push hook and promotion refuse this state. |
| The key is `none` | It uses tracked rules only, with one notice. Promotion refuses this value. |
| The key names a readable, valid host file | It adds the host rules and prints their count. Unsupported forms or keys, duplicate IDs and foreign tables exit with 2. |
| The key names an absent or unreadable file | It exits with 2 and names the path. A relative path also exits with 2. |

The scan combines `.gitleaks.toml` and the host file in a temporary configuration file for gitleaks.
The first nonblank, non-comment line of the host file must be `[[rules]]`.
Use only `[[rules]]` and `[[rules.allowlists]]` tables. Keep values and arrays on one line.
Each rule needs a unique ID starting with `host-` and `regex` or `path`.
A key must occur only once in each table.
Use UTF-8 without a byte order mark and LF line endings. CRLF or BOM input exits with 2.
A host ID must not match an ID in `.gitleaks.toml`.
Unknown keys are refused.

| Table | Supported keys |
|---|---|
| `[[rules]]` | `id`, `description`, `regex`, `path`, `secretGroup`, `entropy`, `keywords` |
| `[[rules.allowlists]]` | `description`, `condition`, `commits`, `paths`, `regexes`, `regexTarget`, `stopwords` |

Use letters, digits, underscores and hyphens in IDs. Gitleaks validates the remaining TOML syntax and regular expressions before scanning.
Parser refusals name the rule ID or line number and one cause.
An empty file reports `host file has no [[rules]] table`.

`promote.sh` always needs a real host rules file. It refuses `ok.hostRules=none`.
It reads these fields of each rule:

| Field | Use |
|---|---|
| `id` | The rule ID in finding output. |
| `regex` | The pattern for a line. Promotion refuses a rule without a regex instead of silently dropping it. |
| `path` | Optional. A pattern for the file path. Without it, the rule applies to the whole tree. |

Use `id = "host-name"` and the exact single-line forms shown above.
Write `regex` and optional `path` between `'''` marks on one line.
Do not indent these assignments or the `[[rules]]` line.
Promotion refuses an unsupported field form with its rule ID or line number and the cause.
A path-only rule can scan successfully but cannot promote.

Promotion uses Perl-compatible regular expressions (PCRE) for content and path filters.
Promotion compiles each regex and path with PCRE first. Before the scan, it validates the merged configuration with gitleaks in a temporary worktree of the snapshot commit.
A compilation failure names the rule ID and exits with 2 without printing the pattern.
Git and `grep` must support PCRE. No conversion to POSIX patterns occurs in the host check.
Every failed filter stops promotion with a scanner error.
Use patterns supported by both PCRE and gitleaks' RE2 engine, which does not support lookarounds or backreferences.

Gitleaks defaults skip `gitleaks.toml`, SVG files and lock files.
Promotion checks host patterns on the snapshot tree independently.
It also checks `.gitleaks.toml`.
The first filter pass uses the C locale and treats file content as bytes, including invalid UTF-8 and NUL bytes.
A second pass uses `C.utf8`, or `C.UTF-8` when available, for accented case-insensitive matches in content and paths.
A UTF-8 decode error discards that filter's second-pass result; other filter errors still stop promotion.
Without a UTF-8 C locale, promotion prints `not verified: utf-8 pass` and runs only the byte pass.
In that case, accented case-insensitive matches are not verified.
The host check reads Git-binary files, including files marked `-diff` or `binary`, as text.
NUL-separated tree fields keep colon-containing paths distinct from matched content.
Paths with tabs or newlines cause a scanner error rather than a partial scan.
The check matches individual lines, not encoded or compressed content, and reads Git blobs rather than external submodule or large-file storage.

## Build the image

```sh
scripts/tenant/build.sh -t open-knowledge:local
```

The build needs BuildKit: use `docker buildx`, or a Docker version where BuildKit is the default builder. `deploy/Dockerfile` uses heredoc `RUN` blocks, which need the BuildKit Dockerfile frontend.

The first line of `deploy/Dockerfile` pins the frontend image by digest. The digest fixes its content even if the tag changes. BuildKit can still contact the registry for metadata or missing layers.

Run `scripts/tenant/pins.sh` to list the upstream version, tarball sha512, base image, scanner image, frontend and pnpm version with their sources. The command checks `EXPLAINER.md` and `deploy/docs/*.md`, without Docker or Node.js. Pin values occur only in their single rows in the "Release facts" table of `EXPLAINER.md`. Exit 0 means agreement, 1 means a doc mismatch or repeated literal, and 2 means the check cannot run.

The variables in the table are environment variables of `build.sh`. The script passes each variable that is set as a build argument. The script exports the Git revision with `git archive`, so uncommitted changes outside `deploy/` do not enter the image. It sets the `OK_REVISION` label to the commit ID.

| Option or variable | Effect |
|---|---|
| `-s <rev>` | Builds from `<rev>`. The default is `HEAD`. |
| `-v <version>` | Optional. Must equal the upstream version, never the portable version. Without it, the script uses `OK_VERSION` from the copied Dockerfile or its environment override. It writes that version into the package manifests. |
| `OK_VERSION`, `OK_NPM_INTEGRITY` | Select the npm tarball that supplies the native addons, and its sha512. |
| `OK_SOURCE` | Sets the `org.opencontainers.image.source` label. The default is the upstream GitHub URL, because this repository holds no URL of your repository. Set `OK_SOURCE` to the URL of the repository that builds the image. |
| `NODE_IMAGE` | Replaces the pinned base image. |
| `OK_UID`, `OK_GID` | Set the user of the container. The default is `10001`. |

## Build behind TLS inspection

A TLS-inspecting proxy replaces the server certificates with certificates of its own CA. The build needs that CA in the Node CA store of the build stages.

Two stages of `deploy/Dockerfile` connect to `registry.npmjs.org` through Node:

- The `native` stage fetches the npm tarball with the Node `fetch` function.
- The `build` stage runs `npm` and `pnpm`, which are Node programs.

Node uses its own CA store, not the CA store of the Docker daemon or of the build host. A CA in the Docker daemon, in `buildkitd.toml` or in the Colima VM is therefore not enough. The variable `NODE_EXTRA_CA_CERTS` adds a CA file to the Node CA store.

The tarball URL is fixed in `deploy/Dockerfile`. It is not a build argument. The build host needs a path to `registry.npmjs.org` through the proxy.

Use one of these two paths:

1. Set `NODE_IMAGE` to a Node 24 image from an internal mirror that already trusts the CA of the proxy. The image must set `NODE_EXTRA_CA_CERTS` to the CA file. Pin the image by digest.
2. Build a local base image from an override Dockerfile stage, then pass it as `NODE_IMAGE`. The stage starts from the default `NODE_IMAGE` of `deploy/Dockerfile`, adds the CA file and sets `NODE_EXTRA_CA_CERTS`:

```Dockerfile
ARG NODE_IMAGE
FROM ${NODE_IMAGE}
COPY proxy-ca.pem /usr/local/share/ca-certificates/proxy-ca.crt
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/proxy-ca.crt
```

```sh
node_image=$(sed -n 's/^ARG NODE_IMAGE=//p' deploy/Dockerfile)
docker build --build-arg "NODE_IMAGE=$node_image" -t ok-node-ca:local -f <override-dockerfile> <directory-with-proxy-ca.pem>
NODE_IMAGE=ok-node-ca:local scripts/tenant/build.sh -t open-knowledge:local
```

The CA file of path 2 also enters the runtime image, because all stages use `NODE_IMAGE`. A CA certificate is public data, not a secret.

A BuildKit secret (`RUN --mount=type=secret`) keeps the CA out of the image, but it needs a change of `deploy/Dockerfile`. This repository does not have that change.

Not verified: both paths. They are documented only. No build through a TLS-inspecting proxy was tested.

## Target runtime

The image is verified on `linux/amd64` only.

- A Mac with Apple Silicon builds `linux/arm64` by default. To build for `linux/amd64`, run `DOCKER_DEFAULT_PLATFORM=linux/amd64 scripts/tenant/build.sh ...`. The Docker CLI reads this variable as the default platform. The image then runs under emulation. Not verified on a Mac.
- To use a native `linux/arm64` image, build and test it on the target first. Not verified: the arm64 build, and the arm64 native file of the npm tarball. The `native` stage checks only the `linux-x64-gnu` file.
- On a Mac, one option is Colima with the Docker runtime. Install it with `brew install colima docker docker-compose docker-buildx`. Set `cliPluginsExtraDirs` in `~/.docker/config.json` to the Homebrew plugin directory (`$(brew --prefix)/lib/docker/cli-plugins`), so that the Docker CLI finds `docker compose` and `docker buildx`. Start the VM with `colima start --cpus 4 --memory 8`, because the build needs more than the default 2 CPUs and 2 GiB. Not verified on a Mac.

## Run with the generic Compose file

1. Copy `deploy/.env.example` to a path outside the repository, or to an ignored path such as `.local/host/ok.env`. Git ignores `.env` and `.local/`.
2. Set `OK_EXTERNAL_URL` to the public URL of the service. Compose refuses to start without it.
3. Set `OK_IMAGE` to the tag of your build.
4. Give `--env-file` on every Compose command. Compose then uses the same values for `config`, `up`, `logs` and `down`.

```sh
docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env config
docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env up -d --no-build
docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env logs --tail=100
```

Compose names the data volume `<project>_data`. The examples use the project name `ok-portable`, so the volume is `ok-portable_data`. Do not give the project name of another deployment on the host. Compose then attaches the new service to the volume of that deployment.

`deploy/compose.yaml` has a `build` section. Without `--no-build`, `up` builds an image from the current tree when the image of `OK_IMAGE` is absent. Build the image with `build.sh` first, and give `--no-build` to `up`.

The service publishes port 8080 on `OK_PUBLISH_ADDRESS:OK_PUBLISH_PORT`. The default is `127.0.0.1:8080`. The container sets `OK_ALLOW_EXTERNAL=1`, and the server has no authentication. Put an authenticating edge server in front of the port.

Warning: any process that reaches the published port or the network of the container can read and change all documents. Keep the port on loopback, and do not attach the container to a shared network without a reason.

## Add host values with an override file

Keep host values out of the repository. Write a second Compose file outside the repository or under `.local/`. Give both files and the env file on every command.

```sh
docker compose -p ok-portable \
  -f deploy/compose.yaml \
  -f .local/host/compose.host.yaml \
  --env-file .local/host/ok.env \
  up -d --no-build
```

An override file can add a bind mount, an external network, or labels. Mount a directory of another system with `:ro` unless its owner approves write access.

## Hardening in the generic files

The kit pins the base image, checks the tarball hash and runs the server without root privileges.
Its Compose defaults remove extra privileges, stop skill-install reports, reduce CLI file logs and prevent launcher autostart.
The [file-state table](hardening.md#state-of-the-files-in-deploy) separates supplied protections from operator actions.

## Limit egress

The kit installs no egress firewall, and the core server needs no external host.
Deny outbound traffic by default and allow only approved destinations.
The [network host tables](hardening.md#network-hosts) separate build, container, browser and editor rules.

## Configure the knowledge base

The data volume holds the configuration of the knowledge base in two files. `/data/.ok/config.yml` exists after the first start. `/data/.ok/local/config.yml` does not exist after the first start. The image has no text editor, so add the lines with `tee -a` in the container. Run each command one time.

Warning: a second run adds duplicate keys and makes the file invalid. The server can drop that layer and restore defaults.

Add these values to `/data/.ok/config.yml`:

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

Add these values to `/data/.ok/local/config.yml`:

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

`linkPreviews.enabled` belongs in the local file. The server ignores the key in `/data/.ok/config.yml`.

Check the result. The output must say `✓ Configuration valid` and name both files, without a parse error. Read the text: an invalid layer can also return exit code 0.

```sh
docker compose -p ok-portable -f deploy/compose.yaml --env-file .local/host/ok.env \
  exec -T openknowledge ok config validate
```

## Pin the host MCP launcher

`ok init` can write an MCP entry that runs `npx -y @inkeep/open-knowledge@latest mcp`. That entry downloads the newest release at each launch. Install the version of `OK_VERSION` in `deploy/Dockerfile` instead.

`npm audit signatures` examines the packages of a project directory. It does not examine a global install: with the option `-g` it stops with `EAUDITGLOBAL`. Examine the package in a scratch directory first, then install it:

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
```

The audit also checks attestations. Without installed dependencies, it reports `found no installed dependencies to audit`.

Remove the scratch directory after the check. `--ignore-scripts` prevents package install scripts during the check, not during the global install.

For an MCP client on the same machine as the container, set the MCP entry of the editor to this value. Give the published port of the container (`OK_PUBLISH_PORT`):

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

With `--port`, `ok mcp` forwards MCP messages to `http://127.0.0.1:<port>/mcp`, the server in the container. It also holds a keepalive WebSocket to `ws://127.0.0.1:<port>` and retries when the server is down.

Without `--port`, `ok mcp` does not connect to the container. It works on a local project. On macOS with the Desktop app installed, it can proxy to the app bundle instead. Otherwise, if no server runs for that project, it starts `ok start` on the machine. Set `OK_MCP_AUTOSTART=0` in the entry to disable that start.

In the permission settings of the MCP client, deny `mcp__open-knowledge__import`, `mcp__open-knowledge__install` and `mcp__open-knowledge__skills`.

Not verified: the install on a machine and the entry in an editor. The commands ran in a container. The connection with `--port` ran with the `ok` command of the image.

## Upgrade

1. Fetch upstream and merge the new release into your branch. Run `scripts/tenant/scan.sh` and `scripts/tenant/install-hooks.sh --check` after the merge.
2. Change the single `ARG OK_VERSION=` default in `deploy/Dockerfile` to the new upstream release. Read its sha512 with `npm view @inkeep/open-knowledge@<version> dist.integrity` and set `ARG OK_NPM_INTEGRITY=` to that value. Update only the matching rows of "Release facts" in `EXPLAINER.md`, then run `scripts/tenant/pins.sh`. An environment override of `OK_VERSION` also needs the matching `OK_NPM_INTEGRITY`.
3. Build with a new tag, for example `scripts/tenant/build.sh -s <rev> -t open-knowledge:<upstream version>`. The script reads the upstream version from the copied Dockerfile when `-v` is absent. Keep the old tag for a rollback.
4. Back up the volume. The next section gives the command.
5. Set `OK_IMAGE` to the new tag in the env file and run `up -d --no-build`.
6. Check the health state with `docker inspect --format '{{.State.Health.Status}}' <container>`. The value must become `healthy`.

The last upstream sync changed these facts:

- The root `.npmrc` is gone. Its settings are in `pnpm-workspace.yaml`. A `deploy/Dockerfile` that copies `.npmrc` fails at that `COPY` step.
- The package manager version comes from the `packageManager` field of `package.json`, so it needs no change of the Dockerfile. Two commands of the Dockerfile changed for the new pnpm release:
  - `pnpm fetch` runs without `--frozen-lockfile`, because `pnpm fetch` of pnpm 12 does not accept that option.
  - `pnpm deploy` has `--config.allow-unused-patches=true`, because pnpm 12 stops with `ERR_PNPM_UNUSED_PATCH` when the production dependencies of the CLI package use none of the patches in `patches/`.
- The later `pnpm install --frozen-lockfile --offline` still enforces the lock file. It runs without the patch option, so an unused patch in the workspace still stops the build.
- The MCP tools `conflicts` and `resolve_conflict` are gone. An MCP client of the server no longer lists them.

## Back up and roll back

A persistent volume is not a backup. Stop the service or accept a copy of live files, then copy the volume to a file. The commands use the base image of `deploy/Dockerfile`, pinned by the same digest:

```sh
node_image=$(sed -n 's/^ARG NODE_IMAGE=//p' deploy/Dockerfile) &&
docker run --rm --network none \
  -v <project>_data:/data:ro \
  -v "$PWD/backup:/backup" \
  "${node_image:?}" \
  tar -C /data -czf /backup/ok-data.tgz .
```

To roll back:

1. Stop the service with `docker compose -p <project> -f deploy/compose.yaml --env-file <env-file> stop`.
2. If the new release changed the data, restore the volume from the backup file:

```sh
node_image=$(sed -n 's/^ARG NODE_IMAGE=//p' deploy/Dockerfile) &&
docker run --rm --network none \
  -v <project>_data:/data \
  -v "$PWD/backup:/backup:ro" \
  "${node_image:?}" \
  sh -c 'find /data -mindepth 1 -delete && tar -C /data -xzf /backup/ok-data.tgz'
```

3. Set `OK_IMAGE` to the previous tag in the env file.
4. Start the old image with `up -d --no-build`. The server starts on the same volume.

Warning: the restore command deletes all files in the volume before it extracts the backup. Check the volume name and the backup file first.

## Check the version of an image

```sh
docker run --rm --entrypoint ok <image> --version
```

The output must equal `ARG OK_VERSION` of the Dockerfile used for the build. The portable version is in the image tag only.

For a readiness check, run `scripts/tenant/smoke.sh <image>`. Docker selects a free loopback port by default. Set `SMOKE_PORT=<free port>` to use a port you checked first. The script captures container output before startup and prints the last 20 lines if the container stops or readiness times out. It measures the readiness interval with `date +%s`, with a 90-second limit.
The timeout message gives elapsed seconds. Docker operations and cleanup can add time.
It removes its containers, anonymous volume and temporary log directory on exit.

## Release identity

| Item | Source |
|---|---|
| Upstream version | `ARG OK_VERSION` in `deploy/Dockerfile` |
| Package version in the image | `build.sh` writes the upstream version into the package manifests. An explicit `-v` must match it. |
| `OK_VERSION`, `OK_NPM_INTEGRITY` | They pin the upstream npm tarball that supplies the native addons. They change only on an upstream sync. |
| Release tag | `portable-vX.Y.Z`, an annotated tag on the release commit. The public line starts at `portable-v0.2.0`. A version number of the earlier merge chain is never used again. |
| Release commit | One snapshot commit for each release. Its first parent is the earlier release commit, and its last parent is the upstream release commit. The first release has the upstream release commit as its only parent. |
| Commit and tag identity | `OpenKnowledge Release <noreply@example.com>` |
| Image tag | `<upstream version>-p<portable version>` |

## Clone from a bundle

A Git bundle moves `portable` and its release tags to another Git server without a network path between the two hosts. After a clone from the bundle, `origin` points at the bundle file.

1. Clone the branch `portable` from the bundle.

   ```sh
   git clone -b portable <bundle> <dir>
   cd <dir>
   git tag --list 'portable-v*'
   ```

   The clone has the branch `portable`, the remote-tracking branch `origin/portable` and the tags of the bundle.
2. Create `upstream` and the release remote `github`. The script prints the bundle path as the `origin` URL and does not change it.

   ```sh
   SHARED_URL=https://github.com/<organization>/<repository>.git scripts/tenant/setup-remotes.sh
   ```

3. Install the hooks. The `pre-push` hook scans each pushed ref. For `github`, it refuses each refspec other than `refs/heads/public:refs/heads/portable` and a `portable-v*` tag of the public line.

   ```sh
   scripts/tenant/install-hooks.sh
   scripts/tenant/setup-remotes.sh --check
   ```

   Fetch upstream before you set `ok.historyBase`. Choose an upstream commit that precedes each pushed tip.
   Without it, the hook may scan the whole upstream history. Fetching upstream does not exclude it.

   ```sh
   git fetch upstream
   git config ok.historyBase <upstream commit or ref>
   ```

   Set `ok.hostRules` to the absolute host-file path from "Host rules" when you have host rules.
   For a clone without host rules, use:

   ```sh
   git config ok.hostRules none
   ```

   Publish clean history to a new remote. Fix findings on the development branch, then promote again.

4. Make the local branch `public` from `portable`. Then push it and each release tag by name. Do not use `--all`, `--tags`, `--follow-tags` or `--mirror`.

   ```sh
   git branch public portable
   git push github refs/heads/public:refs/heads/portable
   git push github refs/tags/portable-v0.2.0
   ```

   The hook reads the public line from the local branch `public` and needs the fetched upstream refs.

   Give each tag of `git tag --list 'portable-v*'`.

   Each `portable-v*` tag carries the history of its tagged commit.
   For a new ref, the hook scans commits outside the base and the remote's existing, locally available tips.
   A release push requires a host file or explicit `none`.
   With a host file, an old matching addition in that range stops the push.
   Fix findings on the development branch before you push.
5. Check the remote. The result lists only `refs/heads/portable` and the `portable-v*` tags, each tag also with its `^{}` line. A `HEAD` line can also appear when `portable` is the default branch.

   ```sh
   git ls-remote github
   ```

## Promote to portable

`scripts/tenant/promote.sh` is the one command that makes a release. The promotion mode is the snapshot mode, and it is the one promotion mode of this repository.

Each release is one snapshot commit on the local branch `public`:

| Part | Content |
|---|---|
| Tree | The tree of `local-dev` at the source commit, without each path of `scripts/tenant/public-check.development`. |
| First parent | The earlier public release commit. The first release has none. |
| Last parent | The upstream release commit of the version: the commit on the first-parent history of `refs/remotes/upstream/main` with the subject `main reset: post-stable v<upstream version>`. The version comes from `ARG OK_VERSION` of the source, and the package manifest of that commit must hold the same version. |
| Identity | `OpenKnowledge Release <noreply@example.com>` as author, committer and tagger. The dates are the committer date of the source commit, in UTC. |
| Message | `OpenKnowledge portable X.Y.Z` |

The public line keeps the upstream history, which later upstream syncs need. It holds no commit of the development history of the fork.
The same source commit, parents and version always give the same snapshot commit ID.

```sh
scripts/tenant/promote.sh --version X.Y.Z [--push --visibility public|private] [--yes] [--accept-visibility] [--remote github] [--source local-dev]
```

Run the command from the worktree of `local-dev`. It builds the snapshot tree with a temporary index and `git commit-tree`, and it moves `public` with `git update-ref`. It never checks out `public`, and it refuses to run while a worktree holds that branch.

### The dry run

Without `--push`, the command is a dry run: it runs every check, prints the proof and the plan, and changes no ref.
The dry run writes the objects of the snapshot commit into the object store, because the checks read that commit. No ref names them.
It also runs `git worktree prune` and uses a temporary detached worktree of the snapshot commit for the scans, which it removes on exit.

### The proof

For each release, the command prints and checks this list:

```sh
git rev-list <snapshot commit> --not <upstream release commit>
```

Every listed commit must be a public release commit: the snapshot commit itself, or an earlier release on the first-parent chain of `public`.
Each of them must carry the release identity, and each earlier one must have a `portable-v*` tag.
So every ancestor of the snapshot commit is an upstream commit or an earlier public release commit.
A `portable-v*` tag of another chain must not be an ancestor. The command refuses a listed commit of any other kind and prints its ID and subject.
The first public release lists exactly one commit.

### Remotes and refspecs

| Remote | Refspecs of the push |
|---|---|
| `github` (the default), and each other remote that is not `origin` | `refs/heads/public:refs/heads/portable` and `refs/tags/portable-vX.Y.Z:refs/tags/portable-vX.Y.Z` |
| `origin` | `refs/heads/public:refs/heads/public` and `refs/tags/portable-vX.Y.Z:refs/tags/portable-vX.Y.Z` |

One run pushes to one remote. To push the same release to a second remote, run the same command again with the other `--remote`.
The command then finds the tag on the head of `public`, builds the snapshot again, requires the same commit ID, and pushes that release.
When the source moved in the meantime, the IDs differ and the command asks for a new version.

`--visibility` says what you expect of the release repository: `public` or `private`. `--push` needs it. The script compares it with the real visibility when it can read that.

The script needs the host rules file of the section "Host rules". Without it, the script stops at the first check.
It also refuses `ok.hostRules=none`.

When the remote has no branch of the public line, the promotion is a first push, even in a dry run.
The `pre-push` hook then needs the Git config key `ok.historyBase` to keep the upstream history out of its scan range.
Without the key, the script refuses a first push.
A configured base must precede the upstream release commit.
A missing upstream ref stops the run. Run `scripts/tenant/setup-remotes.sh`, then `git fetch upstream`.
A remote branch that is not a release commit of the public line stops the run: that remote holds another chain.
The command never forces a push. Replace or empty such a repository yourself before the first push.
Fix a finding on the development branch, then promote again. No option bypasses a finding.

| Number | Check or action | Refusal |
|---|---|---|
| 1 | The working tree is clean, and no worktree holds `public`. The source is not `public` or `portable`. The repository is not shallow. `core.hooksPath` is not set. `ok.hostRules` names a readable file with one rule or more, not `none`. The file must use the supported rule forms. Parser refusals name a rule or line and one cause. Host IDs must start with `host-` and include a name. PCRE compilation must succeed. | Exit 1 for a prerequisite refusal. Pattern compilation and CRLF or BOM errors exit with 2. `--push` without `--visibility` also gives exit 1, before the first check. |
| 2 | `setup-remotes.sh --check` passes. This also checks the hooks. | Exit 1. |
| 3 | Finds the upstream release commit for `ARG OK_VERSION` of the source. Exactly one post-stable commit must exist, its package manifest must hold the version, and the source must contain it. A configured `ok.historyBase` must precede it. Reads `public` as the earlier release. When the tag `portable-vX.Y.Z` exists, it must be an annotated tag on the head of `public`; the run then pushes that release. | Exit 1. The message names the remedy. A lightweight tag is refused in the dry run too. |
| 4 | Builds the snapshot tree and the snapshot commit. Prints the commit, the tree, the number of excluded development-only files and the parents. | Exit 1 when the earlier release already has this tree, or when an existing tag does not match the snapshot. Exit 2 when the development-only list cannot be read. |
| 5 | The proof of the section "The proof". | Exit 1. The list shows at most 10 commits of another kind, then their count. |
| 6 | The remote exists, is not `upstream` and does not point to the GitHub upstream. The script reads the push URL with `git ls-remote --refs`. The branch of the public line on the remote, when present, must be a release commit of the line. For a remote that is not `origin`, each `portable-v*` tag there must be a local tag of the line. | Exit 1 when the remote is unreadable, when the tag exists on the remote, when the remote holds another chain, when a remote tag and the local tag of that name are different objects, or when a first push has no history base. The message for another chain tells you to replace or empty that repository. |
| 7 | When `gh` is installed and the remote is a GitHub URL, `gh auth status` must pass, and the script reads the visibility with `gh repo view <owner>/<repo> --json isPrivate`. It compares the result with `--visibility`. When `gh` cannot tell, the script prints `not verified: visibility` and the reason. With `--visibility public`, the checks then treat the remote as public. | Exit 1 when the visibility is not the value of `--visibility`. `--push` with `--visibility private` needs `--accept-visibility` when the visibility is not verified. `--visibility public` refuses `--accept-visibility` before the first check. |
| 8 | `X.Y.Z` is greater than every other local `portable-v*` tag, of every chain. While `public` does not exist, `X.Y.Z` must be `0.2.0` or greater: the public line starts at `portable-v0.2.0`. The script also reads the `portable-v*` tags from the push URL with `git ls-remote --tags`, and `X.Y.Z` must be greater than the last tag there. When the remote does not answer, the script prints `not verified: remote tags` and continues. | Exit 1 before any change. A release never takes the name of an earlier tag. `--push` stops with exit 1 when the remote tags are not verified. |
| 9 | Checks out the snapshot commit in a temporary detached worktree. Gitleaks validates the merged configuration there. Scanner self-test: the script runs the gitleaks image with `--version` and no network. `GITLEAKS_IMAGE` selects the image, as for `scan.sh`. Then `scan.sh` checks the snapshot tree, and `scan.sh --history` checks the snapshot commit. Both scans apply the host rules. Each scan must print a gitleaks summary. No finding bypass exists. | Scanner errors exit with 2; findings exit with 1. Invalid scan input also stops promotion with exit 2. |
| 10 | Each host rule checks the snapshot tree. A rule with a `path` applies only to matching file paths. | Exit 1. Findings print file, line number, commit and rule ID only. Matched text is never printed. A failed command or filter exits with 2. |
| 11 | Runs `public-check.sh --development-only`, `--tree` and `--identities` on the snapshot commit. Then prints the identities of the commit and the tagger. | Exit 1 for findings, exit 2 when a check cannot run. |
| 12 | Prints the plan: mode, source commit, snapshot commit and tree, parents, new version, remote name and URL without credentials, the two refspecs, the refs on the remote, and the commits that leave. On a first push it prints `first push:` with the upstream release commit and the number of release commits. It prints a `warning:` line for each foreign ref on the remote, and for each file in an allowlist of `.gitleaks.toml` that changed since the earlier release. | A warning does not stop the run. Examine it before the push. The dry run stops here with exit 0. |
| 13 | Moves `public` to the snapshot commit with `git update-ref`, guarded by the earlier value. Writes the annotated tag `portable-vX.Y.Z` with the message `portable X.Y.Z`. Checks the tagger, the tag target and the identities again. | Exit 1. When the tag fails, the script prints the command that moves `public` back. |
| 14 | `git push --dry-run <remote>` with the two refspecs, then the push of those two refs. Both use `push.followTags=false`. | Exit 1. The local branch `public` and the tag stay. |
| 15 | Reads the push URL again. The branch and the tag must have the new values. A ref that is new after the push and is not one of the two is foreign. `refs/pull/*` is ignored. For `--remote origin`, the script skips the foreign-ref check and says so. When the visibility was verified before, the script reads it again and compares it with `--visibility`. | Exit 3. The script deletes nothing. |

Every remote read uses the push URL, including version and post-push checks.
The upstream guards compare lowercase URLs after normalizing repeated host slashes, a trailing host dot, explicit or empty ports, and trailing slashes.
The push commands never pass `--all`, `--tags`, `--follow-tags`, `--mirror` or `--force`.
The script removes credentials from the remote URL before it prints the URL.

Warning: the plan prints the source commit ID and paths. Check the output for private data before you share it.

Warning: fix a finding on `local-dev` through a topic branch, never on `public`. Then run the promotion again.

### Where you confirm

1. Run the dry run and read the proof and the plan.
   Confirm the version, remote, visibility, two refspecs, parents and commits that leave.
2. Fix findings on `local-dev` through a topic branch. Then promote again.
3. Push: with `--push` and without `--yes`, the script prints the plan and asks `Continue? [y/N]` before it writes `public`.
   It accepts `y`, `Y`, `yes` or `YES`. Other answers stop the run with no change.
   Without a terminal, the script stops with exit 1.

Pass `--yes` only after you confirmed the plan.

### After the push

1. Check that the tag commit equals the head of the public line on the remote.
   A new release repository lists one branch and one tag after the first release, the tag also with its `^{}` line.
2. Build from a clean clone of the tag with `build.sh`, test the image with `smoke.sh`, and check the revision label of the image.
3. Record the tag, the commit and the remote refs in the release record.

If the push fails, the local branch `public` and the tag stay. Fix the cause, then run the same command again. It pushes the existing release.

## Continuous integration

The workflow `.github/workflows/portable-release.yml` runs on a tag `portable-vX.Y.Z`. It scans the source, builds the image, tests it with `scripts/tenant/smoke.sh`, pushes it to the registry and records the digest. The job runs only when the repository variable `OK_REGISTRY` is set.

[ci.md](ci.md) gives the steps, the variables, the secrets and the prerequisites of the runner.
