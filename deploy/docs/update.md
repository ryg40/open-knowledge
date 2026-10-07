# Trial upstream updates

`scripts/tenant/update.sh` detects pin changes, tests an upstream release, and reads its release notes.
Each action prints one JSON object on standard output. Logs go into the work directory.
The command pushes no ref or image and does not use Compose or deployment data.

## Requirements

Use Node.js 22 or newer, npm, Git, Docker with BuildKit, and the tools required by the installer kit.
The port check needs `ss` with `-ltn` support.
Use a full clone with a `local-dev` branch and an `upstream` remote.
The upstream URL must be the public OpenKnowledge HTTPS repository, or an absolute local repository path for tests.

The entrypoint is POSIX shell. Its implementation uses only the Node.js standard library.
Node provides JSON parsing, release-note parsing, child-process handling, and structured step records without extra dependencies.
If Node is unavailable, the entrypoint prints a JSON error object and exits 2.

## Detect changes

```sh
scripts/tenant/update.sh detect
```

The command compares these three pins with their current registry values:

- `OK_VERSION` from `deploy/Dockerfile`, against the highest stable npm version.
- `NODE_IMAGE` from `deploy/Dockerfile`, against the current digest of its tag.
- The scanner image from `scripts/tenant/scan.sh`, against the current digest of its tag.

A prerelease does not count as a stable npm version.
The scanner comparison detects a digest change of its pinned tag, not a newer scanner tag.
The result includes `new_version`, `behind`, and a `pins` array with the current and latest values.

| Exit code | Meaning |
|---|---|
| 0 | No pin is behind. |
| 10 | At least one pin is behind. |
| 2 | Invalid input, registry failure, or unavailable tool. |

## Test a release

```sh
SMOKE_PORT=18080 scripts/tenant/update.sh qualify --version X.Y.Z --workdir .local/update-trial
```

The work directory must not be a symlink or an ancestor of the checkout.
The command creates a separate clone under that directory, without shared Git objects or installed hooks from another clone.
It starts from `local-dev` and fetches only `upstream/main`, with `--no-tags`.
It sets the scratch remote's push URL to `DISABLED`.

The selected commit must be the unique first-parent `main reset: post-stable v<version>` commit.
Its `packages/cli/package.json` must declare the requested version.
A matching tag name alone does not select a release.

The trial merges that commit into `sync/v<version>`.
A conflict fails the merge. The command does not resolve it.
After a successful merge, it installs and checks hooks in the scratch clone only.
It sets the version and npm tarball sha512, updates the release-facts rows, and commits the trial pins there.
The package-manager facts row follows the merged manifest.
These trial commits use a neutral identity and do not leave the scratch clone, except in a bundle that `--bundle` requests.

Each step has `name`, `exit_code`, `status`, `log_path`, and `duration_ms`.
A skipped step has `exit_code: null` and a log that names the dependency failure.
A failed step fails the whole run. Independent checks still run.

| Step | Check |
|---|---|
| `hooks-check` | `install-hooks.sh --check` in the scratch clone. |
| `pins-check` | Agreement between pin sources and documentation. |
| `scan-tree` | The scratch tree and staged files, using tracked rules. |
| `scan-range` | The commits added after the original `local-dev` tip. |
| `public-check` | Complete fork files against the selected release. |
| `port-check` | `ss -ltn` must show no listener on `SMOKE_PORT`. The default is 18080. |
| `build` | `build.sh -v` receives the upstream version. |
| `smoke` | `smoke.sh` checks readiness on the checked loopback port. |
| `image-version` | The first line of `ok --version` must exactly match the requested version. |
| `scan-image` | Gitleaks scans added image layers. Findings in pinned base layers are informational notes. |
| `cleanup` | Removes trial containers, anonymous volumes, image, clone, and temporary files. |

Failed scanner records include redacted finding metadata. Full redacted output stays in their logs.
The image check builds a temporary baseline image from the digest-pinned `NODE_IMAGE` in the merged `deploy/Dockerfile`.
It verifies that the trial image starts with the same root filesystem layers.
A missing or mismatched baseline fails the check.
The check scans base layers separately from layers added by `deploy/Dockerfile`, including files deleted in later layers.
It does not expand nested archives or follow filesystem symlinks.
Base-layer findings belong to the upstream image and appear in a redacted `note:` block without changing the step exit code.
Findings in added layers fail the step. Scanner errors fail the step even in base layers.
The command never adds a scanner exception. Cleanup removes the temporary baseline image too.

All test containers have an `ok-update-` name prefix and `--rm`.
The command does not read a deployment env file, a credential store, or inherited registry credentials.
It uses an empty home, Docker configuration, and separate empty npm configuration files.
The subprocess environment keeps `DOCKER_HOST` and uppercase or lowercase HTTP, HTTPS, ALL, and NO proxy variables.
This includes the Docker wrapper, so it uses the selected daemon and network settings.
It applies only tracked scanner rules, not another clone's private host rules.

Warning: an upstream build executes upstream code. Use an isolated runner for source that you do not trust.
Warning: a port can become occupied after the check. Docker then fails the smoke step instead of using another deployment.

Exit 0 means every step passes. Exit 1 means the qualification fails, including invalid qualification input or cleanup failure.
The result records the branch name and upstream commit as evidence, not as a retained branch.
Only logs and `result.json` remain in the generated run directory.

With `--bundle <file>`, a run in which every earlier step passed adds the step `bundle`.
It writes the commits of `sync/v<version>` that `local-dev` does not hold to a Git bundle at that path.
The path must not exist. The result then has the field `bundle`.
The command still pushes nothing. [ci.md](ci.md) describes how the daily workflow uses the bundle.
An abrupt machine shutdown can prevent cleanup. Inspect the recorded image and container names before removing leftovers.
Docker's shared build cache and registry layers remain; the command does not prune resources used by other builds.

## Read notes and input drift

```sh
scripts/tenant/update.sh notes --from X.Y.Z --to X.Y.Z --workdir .local/update-notes
```

The target must be newer than the starting version.
The command fetches upstream into another scratch clone and resolves both post-stable commits.
It reads public GitHub release notes without authentication, for stable releases after `--from` through `--to`.
Missing target notes fail the action instead of producing an empty success.

The JSON includes `breaking: true|false`, `text`, `breaking_changes`, and the original `releases`.
`Major Changes`, `Minor Changes`, and explicit breaking-change sections appear before other text.
Both change headings set `breaking: true`, because this repository uses minor releases for pre-1.0 breaking changes.
Explicit breaking-change entries also set the flag. The command does not infer compatibility from source code.

The `drift` object lists these kit inputs:

- Old and new `packageManager` fields.
- Changes to `pnpm-workspace.yaml` and `patches/`.
- Newly added upstream workflow files.
- A newly added `.husky/` directory.
- Old and new MCP tool names, read from literal `registerTool` calls.

MCP means Model Context Protocol. Dynamic tool names require manual review.
Exit 0 means notes and drift are available. Exit 2 means invalid input, unavailable notes, or another operation failure.

## Test without registries

The following variables name one executable each, not a shell expression:

| Variable | Arguments supplied |
|---|---|
| `OK_UPDATE_NPM_COMMAND` | `view <package> <field> --json`; returns npm-compatible JSON. |
| `OK_UPDATE_DIGEST_COMMAND` | `<image tag>`; returns one `sha256:` digest. |
| `OK_UPDATE_DOCKER_COMMAND` | Normal Docker CLI arguments. |
| `OK_UPDATE_SS_COMMAND` | `-ltn`; returns a listener table. |
| `OK_UPDATE_RELEASES_COMMAND` | `<from> <to>`; returns an array of GitHub-compatible release objects. |

Without overrides, the command uses npm, Docker, `ss`, and the public GitHub releases API.
Injected commands receive the same empty configuration and credential-free environment as normal subprocesses.

```sh
node --test scripts/tenant/update-tests.mjs
```

Tests use the Node standard-library runner, fake executables, and a local bare Git repository.
The filename stays outside Vitest's `*.test.*` globs because these kit tests run without pnpm and read repository-wide inputs.
They need no network or real Docker daemon.
They cover unchanged pins, new versions, changed digests, conflicts, build failures, scanner findings, occupied ports, and breaking release notes.
They also check base-layer notes, added-layer failures, proxy settings, missing Node, cleanup, and the unchanged source checkout.
