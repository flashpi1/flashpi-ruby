# Contributing to flashpi

Read [docs/decisions.md](docs/decisions.md) first: it records why the SDK is built the way it
is. Decisions about the product (names, behavior, releases) belong to the Flashpi team: ask
before changing them.

## Setup

Ruby 3.3 or later (CI runs 3.3, 3.4 and 4.0) and Bundler, which installs the locked tools:

```bash
bundle install
```

## Checks

Run the same checks as CI before every commit:

```bash
bundle exec rake
```

That runs, in order:

- `ruby scripts/openapi.rb check`: the generated types match `openapi/openapi.json`.
- `bundle exec rubocop`.
- `bundle exec steep check`: the gem in strict mode against `sig/`, and the README examples
  (`test/examples/readme/`) against the gem's signatures, the request bodies against the API's
  types included.
- `bundle exec rake test`: Minitest. `COVERAGE=95 bundle exec rake test` also measures the lines
  of `lib/` with the standard library's `Coverage` and fails below 95 %, as CI does. The tests
  also check that `test/examples/readme/` matches the READMEs, and some run against a local HTTP
  server.

CI also runs the tests on Ruby 3.3, 3.4 and 4.0, and builds the gem, checks it file by file and
uses it installed alone on Ruby 3.3 and 4.0:

```bash
gem build flashpi.gemspec
ruby scripts/package_check.rb flashpi-*.gem
```

`bundle exec rake test:live` calls the real API in test mode. It needs `FLASHPI_TEST_API_KEY` (an
`fp_test_` key, read_write) and `FLASHPI_DEMO_ISSUER_ID` (in CI, an organization secret and
variable shared with the other SDKs), and issues one test invoice on the demo issuer, which has a
daily quota: run it only when needed.

## Code conventions

- English for code, identifiers, comments and commit messages. The READMEs are in Spanish
  (`README.md`) and English (`README.en.md`); keep both in step. Every ruby block in them is
  checked: after changing one, run `ruby scripts/readme.rb generate`. Names a block takes from an
  earlier block or from a framework are declared in `test/examples/sig/`.
- Ruby 3.3 or later, RuboCop (double quotes, lines of up to 120 characters) and Steep in strict
  mode.
- The gem has **no runtime dependencies**: net/http, openssl and json from the standard library.
  Models are hashes with the API's camelCase keys as symbols, typed by RBS records generated from
  the OpenAPI document; no model classes.
- Every behavior lives once: retries, idempotency, recovery and errors in
  `Flashpi::Internal::Engine`, the network in `Flashpi::Internal::Transport`, and each operation
  is one method of a resource in `lib/flashpi/resources/`, with its signature in
  `sig/flashpi/resources.rbs`.
- Resource methods mirror the API in snake_case: `create`, `list`, `get`, `update`, `delete`,
  then actions named after the operation (`send_email`, `rotate_secret`, `replay`, ...). Path ids
  come first, then the body or the filters (a hash), then the per-call options as keywords.
  `test/operations_test.rb` checks that every operation of the OpenAPI document has exactly one
  method, which sends it, and whose signature takes and returns the contract's types.

## The API contract

`openapi/openapi.json` is a copy of the public document at
https://flashpi.com.ec/docs/openapi.json and `sig/flashpi/types.rbs` is generated from it. Never
edit either by hand:

```bash
ruby scripts/openapi.rb sync      # download the document and regenerate the types
ruby scripts/openapi.rb generate  # regenerate from the committed copy
```

The `OpenAPI sync` workflow does this every day and opens a pull request when the contract
changes. New operations or fields may need a method or a hand-written type in `sig/flashpi/`.

## Commits and releases

Commit with [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`,
`docs:`, `test:`, `ci:`, `chore:`). They drive the version and the changelog:
[release-please](https://github.com/googleapis/release-please) keeps a release pull request
open, and merging it tags the version and publishes it to RubyGems from the `Release` workflow,
with RubyGems trusted publishing (OIDC, no API key). release-please writes the version to
`lib/flashpi/version.rb` and the CHANGELOG. `Gemfile.lock` holds no version of the gem itself
(the Gemfile lists the tools only), so a release never touches it.

While the version is 0.x, `feat:` raises the minor version and `fix:` the patch version.

The release PR and the OpenAPI sync PR are opened with a token of the organization's GitHub
App, so CI runs on them like on any pull request. (One opened with `GITHUB_TOKEN` would get its
CI only after someone approves it.) The Release workflow also starts the live API test
(`live.yml`) on the release branch each time release-please updates it. A dispatched `ci.yml`
run does not count for a pull request's required checks: to run CI again, re-run the PR's own
checks.

### The GitHub App

An app of the `flashpi1` organization, installed on `flashpi-ruby` (as on the other SDKs), with
no webhook and these repository permissions: Contents, Pull requests and Issues, read and write.
Its Client ID is the organization variable `FLASHPI_BOT_CLIENT_ID` and its private key the
organization secret `FLASHPI_BOT_PRIVATE_KEY`, shared with the other SDKs. The workflows create
a one-hour token per run with only the permissions each job needs. To rotate the key, generate a
new one in the app's settings, update the organization secret (not a repository one, which would
shadow it here only), then delete the old key.

The release builds in two jobs. The build job checks out the tag, builds the gem with an exact
Ruby (4.0.9), no Bundler and no gem, and checks it (`scripts/package_check.rb`), with a read-only
token and no secret. The publish job, the only one allowed to get a RubyGems key, checks out
nothing and runs no code of this repository or of any gem: it downloads that file, gets a
short-lived key from `rubygems/configure-rubygems-credentials` and runs RubyGems' own
`gem push`. It runs in the `rubygems` environment, which waits for a maintainer's approval in
GitHub before it publishes. The build job keeps the file for 30 days, as long as GitHub waits for
that approval. If the publish job fails because it expired anyway, open the run and re-run the
"Build the release" job alone (not "Re-run all jobs", which skips the release once it exists):
the publish job runs again after it and waits for approval.

The Ruby of the release jobs is pinned by version in `release.yml`; update it by hand.

### RubyGems trusted publishing

No RubyGems API key exists for this gem: RubyGems trusts the `Release` workflow through OpenID
Connect. RubyGems accepts a **pending trusted publisher** for a gem that does not exist yet, so
every version, 0.1.0 included, is published by the workflow. Before the first release PR is
merged:

1. An owner of the Flashpi RubyGems account (with multi-factor authentication) adds a pending
   trusted publisher at https://rubygems.org/profile/oidc/pending_trusted_publishers: gem name
   `flashpi`, repository owner `flashpi1`, repository name `flashpi-ruby`, workflow filename
   `release.yml`, environment `rubygems`. A pending publisher does not reserve the name, so add it
   shortly before the release.
2. This repository has the `rubygems` environment, with the maintainers as required reviewers,
   limited to the `main` branch.
3. Drop the not-on-RubyGems notice from both READMEs in its own pull request.
4. Merge the release PR. release-please tags `v0.1.0` and the build job builds and checks the
   tag; approve the `rubygems` environment, and the publish job pushes the gem. The first push
   creates the gem, and the pending publisher becomes its trusted publisher.

From then on, versions are published by the workflow only: do not create RubyGems API keys for
the gem.
