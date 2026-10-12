# Continuous integration

This page says what each workflow of this fork does, what the runner needs, and how to run each stage by hand.

| Workflow file | Server | Trigger | Work |
| --- | --- | --- | --- |
| `.gitea/workflows/upstream-update.yml` | Development repository | Once each day, and by hand | Detects a new upstream version, tests it, and opens one pull request into `local-dev`. |
| `.gitea/workflows/checks.yml` | Development repository | Push and pull request of `local-dev`, and by hand | Shell check, secret scan, public-content check, pin check and telemetry check, with the tests of the last three. Image build, smoke test and the test of the telemetry program for a change under `deploy/`. |
| `.github/workflows/public-checks.yml` | Public repository | Each push and pull request | Secret scan and public-content check. |
| `.github/workflows/portable-release.yml` | Release repository | Tag `portable-vX.Y.Z`, and by hand | The release pipeline: scans, public-content check, build, smoke test, image push, digest record. |

A workflow file holds no build logic. It calls the scripts under `scripts/tenant/`. The same commands run on a Linux host, on a Mac and in CI.

No workflow promotes, makes a release tag or pushes `portable`. The release stays one manual action of a maintainer through `scripts/tenant/promote.sh` and its checks. The only branch that a workflow pushes is `sync/v<version>` in the development repository.

The other files under `.github/workflows/` come from upstream. See "Upstream workflows".

## Release pipeline

The release pipeline runs on a tag `portable-vX.Y.Z`. It scans the source, builds the image, tests the image, pushes the image to the registry and records the digest. It builds `linux/amd64` only.

The job runs only when the repository variable `OK_REGISTRY` is set. In a repository without that variable, the job is skipped.

Push only `portable` and the `portable-v*` tags to the release repository. The `pre-push` hook refuses other refs for a remote other than `origin`.

## Prerequisites on the runner

These items apply to each runner:

- The runner has the `x64` architecture. The pipeline does not set a platform, so the image has the platform of the runner.
- The runner has Docker with BuildKit. `deploy/Dockerfile` needs BuildKit.
- The runner has `git`, `tar`, `awk`, `sed`, `grep`, `bash` and the standard utilities listed in [EXPLAINER.md](../../EXPLAINER.md).
- The runner reaches `registry.npmjs.org`. The tarball URL in `deploy/Dockerfile` is fixed.
- The runner reaches Docker Hub for the base image, the scanner image and the shell check image, or `NODE_IMAGE`, `GITLEAKS_IMAGE` and `SHELLCHECK_IMAGE` name mirrors.
- The runner reaches `github.com`. The workflows fetch the pinned actions there, and `scripts/tenant/ci.sh upstream-ref` fetches the upstream branch when the clone does not hold the upstream release commit.
- The workflow check and the upstream update need Node.js 24 or newer; their entrypoints refuse an older Node. The upstream update also needs npm and `ss`. See [update.md](update.md).
- The checkout directory and `$TMPDIR` have the same path for the job and for the Docker daemon. `scan.sh` mounts them. A job container without the Docker CLI, or with the checkout in a named volume, cannot run the kit scripts. On a Gitea server, use a host-mode label (`<label>:host`) of `act_runner` with Node.js 24, the Docker CLI and GNU `grep`, and a work directory bind-mounted at the same path on the runner and on the Docker daemon. Set `OK_RUNNER` to that label.

If the runner is behind a TLS-inspecting proxy, these items also apply:

- The Docker daemon of the runner trusts the CA of the proxy. Image pulls and the push need this.
- The build trusts the CA of the proxy. This is a required step: do the section "Build behind TLS inspection" of [deployment.md](deployment.md). Node uses its own CA store, so the CA in the Docker daemon is not enough.
- `NODE_IMAGE` is a mirror image that trusts the CA of the proxy. Pin it by digest.

The runner has no host rules: the Git config key `ok.hostRules` is not set there. `scan.sh` then uses the rules of `.gitleaks.toml` only, and prints one line that says so. A scanner image override prints the selected image. A scan without a gitleaks summary fails with exit 2.
The scanner validates its configuration against an empty directory before scanning.
A failed host-rule compilation names its ID without printing the pattern or scanner panic text.
The promotion applies the host rules before the tag exists. See the section "Host rules" of [deployment.md](deployment.md).

## Public repository

On a public repository, the run logs, the job summary and the artifact `release-record` are public. They name the image. The image name holds the registry host and the namespace of `OK_REGISTRY`. A log can also hold the error text of the registry. Set `OK_REGISTRY` in a public repository only when the name of the registry can be public.

Warning: a self-hosted runner on a public repository can run code of a stranger. A pull request from a fork can bring a workflow file that selects the label of the runner. Use a hosted runner: the default of `OK_RUNNER` is `ubuntu-latest`. If you must use a self-hosted runner, do these two settings first:

1. Put the runner in a runner group that admits only the workflow `portable-release.yml`.
2. Require approval for all workflows of pull requests from forks.

Not verified: the two settings. No public repository ran this pipeline.

## Variables

Set these as repository variables.

| Variable | Use | Example |
| --- | --- | --- |
| `OK_REGISTRY` | Registry and namespace of the image. The first path segment is the registry host. The job is skipped without it. | `registry.example.com/team` |
| `OK_SOURCE` | URL of your repository for the label `org.opencontainers.image.source`. Optional. | `https://git.example.com/team/open-knowledge` |
| `OK_RUNNER` | Label of the runner. The default is `ubuntu-latest`. | `self-hosted-x64` |
| `NODE_IMAGE` | A mirror of the Node base image. Optional. Behind a TLS-inspecting proxy, the image must trust the CA of the proxy. Pin it by digest. | `mirror.example.com/library/node@sha256:<digest>` |
| `GITLEAKS_IMAGE` | A mirror of the scanner image. Pin it by digest. Optional. | `mirror.example.com/zricethezav/gitleaks@sha256:<digest>` |
| `SHELLCHECK_IMAGE` | A mirror of the shell check image. Pin it by digest. Optional. Development repository only. | `mirror.example.com/koalaman/shellcheck@sha256:<digest>` |
| `OK_SMOKE_PORT` | Loopback port of the smoke test. Optional. Development repository only. The upstream update uses 18080 without it. | `18090` |

`.github/workflows/public-checks.yml` reads no variable. It always uses the hosted runner `ubuntu-latest`.

## Secrets

Set these as repository secrets.

| Secret | Use |
| --- | --- |
| `OK_REGISTRY_USER` | User name for `docker login` |
| `OK_REGISTRY_TOKEN` | Token for `docker login` |
| `OK_UPDATE_TOKEN` | Optional. Development repository only. Token that reads pull requests, pushes `sync/v<version>` and opens the pull request. Without it, the upstream update uses the token of the run. |

No workflow file holds a secret value. `scripts/tenant/workflows.sh check` refuses a secret name that this table does not list for the file.

Use a token with push rights to one repository path only. The token must also have read rights to that path, because the pipeline reads the manifest before the push.

The pipeline gives the token to `docker login` on standard input. The token is in the environment of the login step only. The pipeline prints no secret.

## On a tag

The release tag has the form `portable-vX.Y.Z`, for example `portable-v0.2.0`. The image tag is then `<upstream version>-pX.Y.Z`. Pin values appear only in the "Release facts" table of [EXPLAINER.md](../../EXPLAINER.md). Run `scripts/tenant/pins.sh` to list their sources and check the docs. It exits with 1 for a doc mismatch and 2 when it cannot run.

To run the steps by hand, set the variables first:

```sh
OK_REGISTRY=registry.example.com/team
RELEASE_TAG=portable-v0.2.0
```

1. Check out the tag with the full history. The history scan needs all commits of the range and all release tags.

   ```sh
   git clone <URL of the repository> open-knowledge
   cd open-knowledge
   git checkout "refs/tags/$RELEASE_TAG"
   ```

2. Read the versions. The portable version comes from the tag. The upstream version comes from `deploy/Dockerfile`. The pipeline stops when the tag has another form.

   ```sh
   PORTABLE_VERSION=${RELEASE_TAG#portable-v}
   UPSTREAM_VERSION=$(awk -F= '/^ARG OK_VERSION=/ { print $2; exit }' deploy/Dockerfile)
   RELEASE_COMMIT=$(git rev-parse --verify 'HEAD^{commit}')
   IMAGE=$OK_REGISTRY/open-knowledge:$UPSTREAM_VERSION-p$PORTABLE_VERSION
   REGISTRY_HOST=${OK_REGISTRY%%/*}
   ```

3. Scan the tree. Exit code 1 means a finding.

   ```sh
   scripts/tenant/scan.sh
   ```

4. Find the previous release tag and scan the commits since that tag. When no previous tag exists, the pipeline writes a notice to the job summary and does not scan the history.

   ```sh
   git tag --list 'portable-v*' --sort=-v:refname
   scripts/tenant/scan.sh --history <previous tag>..HEAD
   ```

   The previous tag is the line after `$RELEASE_TAG` in the list.
5. Check the public content. The first command makes sure that the check compares with the upstream release commit. That commit is the one commit `main reset: post-stable v<upstream version>` of the upstream branch, and it holds the pinned version. The upstream tag of a version is an earlier commit and does not hold that version. When the clone does not hold the commit, the command fetches the upstream branch. When no ref that `public-check.sh` reads names the commit, the command makes the local tag `<upstream version>` on it. It does not push the tag. Exit code 1 of the second command means a finding, and 2 means that the check cannot run.

   ```sh
   scripts/tenant/ci.sh upstream-ref
   scripts/tenant/public-check.sh
   ```

6. Build the image. `NODE_IMAGE` and `OK_SOURCE` come from the variables. Without `-v`, the script reads the upstream version from the Dockerfile. The pipeline still passes `-v` explicitly, which must match that version. The portable version is in the image tag only.

   ```sh
   DOCKER_BUILDKIT=1 NODE_IMAGE=<mirror image> OK_SOURCE=<URL of the repository> \
     scripts/tenant/build.sh -s "$RELEASE_COMMIT" -t "$IMAGE"
   ```

7. Test the image. The script reads the version, starts a container with a read-only root file system and waits for `/readyz`. It removes the container at the end.

   ```sh
   scripts/tenant/smoke.sh "$IMAGE"
   ```

   The last line must be `smoke: ok <upstream version>`. The pipeline compares the printed version with the upstream version and stops on a difference. The script needs Docker, a POSIX shell and standard utilities. [EXPLAINER.md](../../EXPLAINER.md) lists them.
   Both the stopped-container and readiness-timeout failure paths print the last 20 captured log lines.
   The script measures a 90-second readiness limit with `date +%s`. The timeout message gives the elapsed seconds.
   Docker operations and cleanup can add time.
8. Log in to the registry.

   ```sh
   printf '%s' "$OK_REGISTRY_TOKEN" | docker login "$REGISTRY_HOST" -u "$OK_REGISTRY_USER" --password-stdin
   ```

9. Check that the image tag does not exist in the registry. The command must fail, and the error must name a missing manifest: `no such manifest`, `manifest unknown`, `MANIFEST_UNKNOWN` or `not found`. When the command succeeds, the pipeline stops with `image tag exists`. On any other failure, for example of the login, the connection or TLS, the pipeline stops and prints the error text. A release tag is never built twice into the same image tag.

   ```sh
   docker manifest inspect "$IMAGE"
   ```

10. Push the image.

   ```sh
   docker push "$IMAGE"
   ```

11. Record the digest. See "Record".

    ```sh
    docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE"
    ```

12. Log out of the registry. The pipeline does this step also when an earlier step fails.

    ```sh
    docker logout "$REGISTRY_HOST"
    ```

## Record

The pipeline writes the tag, the commit, the image, the digest and the upstream version to two places:

- The job summary of the run.
- The file `release-record.txt` in the workflow artifact `release-record`.

```text
tag=portable-v0.2.0
commit=<commit ID>
image=registry.example.com/team/open-knowledge:<upstream version>-p<portable version>
digest=registry.example.com/team/open-knowledge@sha256:<digest>
upstream_version=<upstream version>
```

A deployment uses the digest, not the tag. Copy the digest into the release record of the deployment.

## Checks of the development repository

`.gitea/workflows/checks.yml` runs on each push and each pull request of `local-dev`, and by hand. The job `source` runs these commands. Each one runs by hand in a clone in the same way.

```sh
scripts/tenant/workflows.sh check
scripts/tenant/ci.sh lint
scripts/tenant/scan.sh
scripts/tenant/ci.sh upstream-ref
scripts/tenant/public-check.test.sh
scripts/tenant/public-check.sh
scripts/tenant/pins.test.sh
scripts/tenant/pins.sh
scripts/tenant/telemetry.test.sh
scripts/tenant/telemetry.sh
```

- `workflows.sh check`: see "Check of the workflow files".
- `ci.sh lint` runs `shellcheck -s sh` from a pinned image on each tracked `scripts/tenant/*.sh` and on `deploy/entrypoint.sh`. It mounts the checkout read-only and gives the container no network.
- `scan.sh` scans the tree for secrets. Exit code 1 means a finding.
- `ci.sh upstream-ref` and `public-check.sh`: see "On a tag".
- `public-check.test.sh` tests the exception list of `public-check.sh` in a temporary repository. It needs Git and no network, and it does not need the local tag of `ci.sh upstream-ref`.
- `pins.sh` compares the pin sources with the docs. It also checks that the row "Portable release tag" and the two `RELEASE_TAG=` lines of `EXPLAINER.md` hold one tag.
- `pins.test.sh` tests `pins.sh` and the version defaults of `build.sh` on a temporary copy of the pin sources and the docs. It replaces `docker` with a stand-in command, so it starts no container and needs no network.
- `telemetry.sh` reads `scripts/tenant/telemetry.baseline`. It fails with exit code 1 when `deploy/compose.yaml`, `deploy/Dockerfile`, `scripts/tenant/smoke.sh` or `deploy/no-telemetry.mjs` does not hold a switch or a key of the baseline. It fails too when a kit file names the build setting `VITE_OTEL_ENABLED` of the browser trace exporter, or when `deploy/Dockerfile.dockerignore` does not keep `.env` files out of the build. It also fails when one of these source facts differs from the baseline:
  - A default of the configuration schema. The default of a parent object is a fact only when it differs from the defaults of its keys.
  - The name of an environment variable in upper case that the source reads in the form `env.NAME`, `env?.NAME` or `env['NAME']`. The locale names `LANG` and `LC_*` are not facts.
  - A source line that unpacks the environment object, such as `const { NAME } = process.env` or the same form with `import.meta.env`.
  - A source line that reads a telemetry variable.
  - A host name or an IPv4 address after `http`, `https`, `ws` or `wss` in upper or lower case, and the number of places that name it. An address of the machine itself (a full IPv4 address `127.x.x.x`, or `0.0.0.0`) is not a fact. A host name that starts with these numbers is a fact.
  - The number of addresses in a file whose host comes from a variable.
  - An imported module with a telemetry name.
  - A line outside the application source that names the build setting.

  The guard compares names and lines. It cannot see these forms: a variable name in lower case (`process.env.ok_ping_url`); a variable name that the source computes (`process.env[name]`); the environment object under another name (`const e = process.env`, or a parameter with that default) when the name is not `env`; a request to an address that the baseline already counts; a request whose address the source builds from parts or takes from a variable (`fetch(url)`); a request to a path without a host (`navigator.sendBeacon('/api/usage')`); an address with the host `localhost`; a connection that does not use an address text (`net.connect(443, host)`, `dns.resolve(host)`); a module name that the source builds from parts without a telemetry word in one part. It needs Git and Node.js, and no network. `telemetry.sh update` writes the present source facts into the baseline after a review; `telemetry.sh list --ref <revision>` prints the facts of a revision.
- `telemetry.test.sh` tests `telemetry.sh` in a temporary repository: a changed default, a new key, a changed default of a parent object, a new variable in each access form, an unpacked environment object, a new host, a host in upper case, an IPv4 address, a second place for a listed host, an address with a host from a variable, a `wss` address, a telemetry module, the build setting and a removed switch each give exit code 1. A locale name and an address of the machine itself give exit code 0.

Each test runs immediately before its check. A failed test stops the job, and the step name shows which script is defective.

The job `image` builds the image and runs the smoke test. It runs on a manual trigger, and when a file under `deploy/` differs between the base commit and the head commit. When the base commit is unknown, the job runs. By hand:

```sh
scripts/tenant/ci.sh deploy-changed <base commit> <head commit>
scripts/tenant/ci.sh image
```

`ci.sh image` builds the pinned upstream version into a temporary local tag, runs `smoke.sh`, compares the printed version with the pin, runs `no-telemetry.test.sh`, and removes the image. It pushes nothing. `smoke.sh` also fails when a telemetry path is on in the started container.

`scripts/tenant/no-telemetry.test.sh <image>` tests `deploy/no-telemetry.mjs` as the image holds it. It starts two containers of the image without a network, with a read-only root and with temporary file systems for `/data` and the home directory, and it removes them. It mounts no host directory. In the first container it runs the program on these files and compares the bytes of the result: a new file, lines added at the end, a second run, CRLF line ends, a replaced value, lines added in a mapping, a file that the parser writes, a file with only `null`, a number that the parser would change, two documents, a link inside `.ok`, a link to a file outside `.ok`, a link to a JSON file, a link to a file that does not exist, a link in the home directory, a `local` directory and a `.ok` directory that are links, and an old temporary file. In the second container `/data` is full, and the test confirms that no byte of the file changes for each write method. It needs Docker or Podman, and no Node.js on the host. The upstream update (`update.sh`) does not run this test. The job `image` of `checks.yml` runs it for a change under `deploy/`.

## Daily upstream update

`.gitea/workflows/upstream-update.yml` runs once each day and by hand. It always checks out `local-dev`. [update.md](update.md) describes the three actions of `scripts/tenant/update.sh` that it calls.

| Job | Runs | Work |
| --- | --- | --- |
| `detect` | Always | Compares the pins with the registries. Looks for an open pull request from `sync/v<version>` into `local-dev`. |
| `qualify` | A stable version is new, and no such pull request is open | Tests the version in a scratch clone. Uploads the logs, `result.json` and `qualify.json` as the artifact `qualify`, also after a failure. |
| `notes` | Same condition as `qualify` | Reads the release notes and the changed kit inputs. Uploads the artifact `notes`. |
| `pull-request` | `qualify` and `notes` passed | Pushes the tested commits as `sync/v<version>` and opens the pull request into `local-dev`. |

When `qualify` fails, the run fails, the artifact `qualify` holds the log of each stage, and the job `pull-request` does not start. The workflow then opens no pull request.

The pull request carries the release notes as its text, and the changed kit inputs as JSON. When the release notes hold a `Major Changes` section or an entry with the word `breaking`, the title starts with `[BREAKING]` and the first line of the text is `BREAKING CHANGE`. A `Minor Changes` heading alone does not set the marker. A change of the base image digest or of the scanner image digest opens no pull request: the job `detect` prints a warning line that names the pin.

At most one pull request is open for each version. The job `detect` stops the run when one is open, and the job `pull-request` looks again before the push. A closed pull request does not stop the next run: turn the schedule off, or merge a newer version, to stop a version that you refuse.

The branch `sync/v<version>` holds the commits that `qualify` tested, not a second merge. `qualify --bundle <file>` writes them to a Git bundle after each stage passed, and the job `pull-request` pushes that bundle. The push replaces an older branch of the same name.

To run the stages by hand in a full clone with a `local-dev` branch:

```sh
scripts/tenant/ci.sh upstream-remote
scripts/tenant/update.sh detect
scripts/tenant/update.sh qualify --version X.Y.Z --workdir .local/update-trial --bundle .local/update-trial/sync.bundle
scripts/tenant/update.sh notes --from X.Y.Z --to X.Y.Z --workdir .local/update-notes
```

`ci.sh upstream-remote` adds the remote `upstream` with the public upstream URL and disables its push URL. Then fetch the bundle, push the branch and open the pull request with the tools of your Git server:

```sh
git fetch .local/update-trial/sync.bundle '+refs/heads/sync/vX.Y.Z:refs/heads/sync/vX.Y.Z'
```

The token of the run needs these rights on the development repository: read pull requests, write contents, write pull requests. The jobs ask for them with `permissions`. The server can limit the token of a run below that. Set the secret `OK_UPDATE_TOKEN` then, with a token of an account that has only these rights on this one repository.

A Gitea server starts no workflow for an event that the token of a run causes. `checks.yml` therefore does not run for a pull request that the token of the run opened. `qualify` ran the same checks before. To get a run of `checks.yml` on the pull request, set `OK_UPDATE_TOKEN`.

To turn the schedule off, disable the workflow `upstream-update.yml` on the Actions page of the development repository. The manual trigger stays usable after you enable it again. A second way is to delete the `schedule` lines of the file on the default branch.

Warning: `qualify` builds upstream code on the runner. Use a runner that holds no deployment data and no other credential.

## Workflow directory on the development server

A Gitea server reads the workflow files of a commit from one directory only: the first that exists of `.gitea/workflows` and `.github/workflows`. The server setting `WORKFLOW_DIRS` of the section `[actions]` holds this list. A commit with `.gitea/workflows/` therefore starts no file under `.github/workflows/`. Source: `ListWorkflows` in `modules/actions/workflows.go` and the default in `modules/setting/actions.go` of Gitea 1.26.1.

This rule is per commit. Two cases still start upstream workflows:

- A schedule is read from the default branch only. When the default branch has no `.gitea/workflows/`, the upstream schedules run and the schedule of `upstream-update.yml` does not.
- A push or a pull request of a branch without `.gitea/workflows/`, for example a mirror of the upstream branch, starts the upstream files of that branch.

Do one of these before you turn Actions on:

1. Set `WORKFLOW_DIRS = .gitea/workflows` on the server. The server then never reads `.github/workflows/`. A branch without `.gitea/workflows/` starts nothing.
2. Or make `local-dev` the default branch, and push no branch without `.gitea/workflows/` to that repository.

With the first way alone, the daily schedule still needs `.gitea/workflows/upstream-update.yml` on the default branch.

Verified on a Gitea server with `local-dev` as the default branch: a push of `local-dev` started `checks.yml` only, the schedule started `upstream-update.yml` only, and no upstream file started.

## Checks of the public repository

`.github/workflows/public-checks.yml` runs on each push and each pull request. It runs the secret scan and the public-content check:

```sh
scripts/tenant/scan.sh
scripts/tenant/ci.sh upstream-ref
scripts/tenant/public-check.sh
```

The workflow needs no secret and no variable. Its token has `contents: read` only. It runs on the hosted runner `ubuntu-latest`, never on a self-hosted runner, because a pull request from a fork runs it. Each action is pinned by commit ID. The workflow does not depend on the name, the history or the default branch of the repository: `ci.sh upstream-ref` fetches the upstream branch from the public upstream repository and marks the release commit of the pinned version. A fork branch with the name `main` is not taken for the upstream commit.

`portable-release.yml` runs the same two checks before the build.

## Check of the workflow files

```sh
scripts/tenant/workflows.sh check
node --test scripts/tenant/workflows-tests.mjs
```

`workflows.sh check` reads the four workflow files of this fork. It needs Node.js and no package. It fails with exit code 1 when one of these rules is broken, and with 2 when it cannot run:

- Each file is valid YAML of a small subset: block mappings, block sequences, plain and quoted scalars, and literal blocks. The script refuses comments, flow collections, anchors, tabs and duplicate keys.
- When `python3` with PyYAML is present, the script also parses each file with PyYAML and compares the two results. The line `YAML mode` of the output says which mode ran. Without PyYAML, the check is structural only.
- Each `run` line starts each command with a tracked executable file of the repository, or with one of these standard commands: `awk`, `cat`, `docker`, `echo`, `exit`, `git`, `grep`, `mkdir`, `node`, `printf`, `rm`, `sed`, `set`, `sh`, `tail`, `tee`, `test`. `node` and `sh` need a tracked script as an argument.
- No `run` line holds a workflow expression. Values go through `env`.
- No `run` line names `promote.sh` or `setup-remotes.sh`, runs `git push`, or makes a tag.
- Each action is pinned by a full commit ID.
- Each secret name is in the list for its file. The public workflow names no secret, no token and no variable, has `contents: read` only, and uses `ubuntu-latest`.
- `.gitea/workflows/` holds no other file.

The script does not check the upstream files, and it does not prove that a server accepts a file.

## Upstream workflows

The repository holds upstream workflow files under `.github/workflows/`. This command lists them:

```sh
scripts/tenant/workflows.sh upstream
```

They have no repository guard. Some run on a schedule, and one schedule probes an upstream production URL. On a Gitea server, see "Workflow directory on the development server". On a GitHub repository, do the sequence below.

The server knows a workflow file only after the file is pushed. A file therefore cannot be disabled before the first push. Do this sequence:

1. Before the first push, turn Actions off for the repository. No workflow then runs when the files arrive.

   ```sh
   gh api -X PUT repos/<owner>/<repo>/actions/permissions -F enabled=false
   ```

2. Push `portable` and the tag by name.

   ```sh
   git -c push.followTags=false push <remote> refs/heads/portable refs/tags/portable-vX.Y.Z
   ```

3. Turn Actions on.

   ```sh
   gh api -X PUT repos/<owner>/<repo>/actions/permissions -F enabled=true
   ```

4. At once, disable each upstream file. Run this line in the clone. It keeps `portable-release.yml` and `public-checks.yml` active.

   ```sh
   scripts/tenant/workflows.sh upstream | while IFS= read -r name; do gh workflow disable "$name"; done
   ```

5. Check the result. Only `Portable release` and `Public checks` must be active.

   ```sh
   gh workflow list --all
   ```

6. Set the variables and the secrets. Then start the workflow by hand (see "Re-run"). The guard skipped the job at the tag push, and Actions was off at that time.

Tested: the line of the fourth action against a stand-in `gh` command. It asks to disable each upstream file and no file of this fork. The test is in `scripts/tenant/workflows-tests.mjs`.

Not verified: this sequence on a Git server. Not verified: that the server lists a workflow file that arrived while Actions was off. If `gh workflow disable` does not find a file, push one more commit and run the line again.

An upstream sync can add a workflow file. Do the check again after each promotion.

## Re-run

The job is skipped when a tag arrives before `OK_REGISTRY` is set. Start the workflow by hand with the tag:

```sh
gh workflow run portable-release.yml -f ref=portable-v0.2.0
```

The run checks out the tag, not the branch of the dispatch. A re-run after a completed push stops at the check of the image tag, because the image tag exists.

## Not verified

- A run of the workflow on a self-hosted runner. No GitHub Actions run of this file exists.
- A build behind a TLS-inspecting proxy, and a build with a mirror `NODE_IMAGE`.
- The login, the manifest check and the push with a remote registry. The pipeline needs an HTTPS registry with authentication.
- The error text of your registry for a missing tag and for a refused login. The pipeline counts the tag as absent only when the error names a missing manifest. A connection failure gives another text (`failed to configure transport`), and the pipeline stops. Not verified: the missing-tag check against a plain HTTP registry. Your registry must answer on HTTPS.
- The job `pull-request` of `.gitea/workflows/upstream-update.yml`. `checks.yml` passed both jobs on a Gitea server with a host-mode `act_runner`, `public-checks.yml` passed on GitHub, and the jobs `detect`, `qualify` and `notes` of `upstream-update.yml` ran there with their artifacts. The first candidate version did not qualify, so the pull request job was skipped.
- The action `actions/download-artifact` at its pinned commit on a Gitea runner. `actions/checkout` and `actions/upload-artifact` at their pinned commits ran there; the server needs each action mirrored under the same owner and name when `DEFAULT_ACTIONS_URL` is `self`.
- The rights of the token of a run on a Gitea server: the read of pull requests, the push of `sync/v<version>` and the new pull request.
- The values `github.api_url` and `github.server_url` on a Gitea runner. `scripts/tenant/update-ci.mjs` builds the request address and the push address from them.
- The steps on a Mac.
- Whether an image that another host builds from the same tag has the same digest. No test compared two builds. Use the digest of the record, not a digest from another build.
