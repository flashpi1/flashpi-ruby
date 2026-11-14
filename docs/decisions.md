# Decisions

Decisions about flashpi, the Ruby SDK, newest first. Its design follows the Python SDK,
[flashpi](https://github.com/flashpi1/flashpi-python), and the Node.js SDK,
[@flashpi/node](https://github.com/flashpi1/flashpi-node), whose decisions
([Python](https://github.com/flashpi1/flashpi-python/blob/main/docs/decisions.md),
[Node](https://github.com/flashpi1/flashpi-node/blob/main/docs/decisions.md)) apply here unless
an entry says otherwise. Entries marked as the owner's were taken with the Flashpi product owner;
the others were chosen while porting, after the Python SDK where the owner had not decided, and
are listed so they can be confirmed or changed before 1.0.

## 2026-11-13: the Ruby SDK

### The owner's decisions

- **Gem and repository.** `flashpi` on RubyGems (`require "flashpi"`, `Flashpi::Client`), public
  repository `flashpi1/flashpi-ruby`, MIT license held by SIGNIADIGITAL S.A. Ruby 3.3 or later,
  tested on 3.3, 3.4 and 4.0. First version 0.1.0 through release-please (the manifest starts at
  0.0.0 with `initial-version` 0.1.0, as the Python SDK).
- **No runtime dependencies.** net/http, openssl and json from the standard library. No Rails
  integration in this gem; one may come later as a separate gem.
- **Models are hashes.** Hashes with the API's camelCase keys (`invoice[:accessKey]`), the
  counterpart of Python's dicts and PHP's arrays, typed by RBS signatures generated from the
  OpenAPI document and checked with Steep. The generator is a committed script with a `check`
  mode that CI runs.
- **Tooling.** Minitest, RuboCop and Steep.
- **Publishing.** RubyGems trusted publishing (OIDC) from GitHub Actions, behind a GitHub
  environment `rubygems` that the owner approves, for every version, 0.1.0 included (RubyGems
  accepts a pending trusted publisher). The publish job runs no dependency code.
- **The Python SDK's design.** READMEs in Spanish (`README.md`) and English (`README.en.md`);
  resource style (`client.invoices.create(body)`, `client.documents.list(...)`,
  `client.issuers.establishments.create(issuer_id, body)`) with snake_case methods and
  resources; an automatic Idempotency-Key reused by the retries; up to 2 retries with backoff and
  jitter; a Retry-After of 60 s or less; the wait for a 409 `idempotency_key_in_progress`; the
  recovery of a document an earlier attempt created; a DELETE answered 404 after a lost answer;
  one deadline per attempt (net/http's open, read and write timeouts plus a total deadline); API
  key and header validation; English errors with `language: "es"`; the `FLASHPI_API_KEY`
  fallback; Enumerable auto-pagination; Standard Webhooks verification; secrets never in
  `inspect`, exception messages or backtraces; release-please from 0.1.0; the live API test on
  the release PR only; the flashpi-bot GitHub App's token for the bot's PRs; grouped Dependabot.

### Chosen while porting (to confirm)

- **Names.** The errors are `Flashpi::Error` (Python's `FlashpiError`, named as Ruby gems name
  their base error), `Flashpi::APIError` with a subclass per status (`BadRequestError` to
  `InternalServerError`), `Flashpi::APIConnectionError` and `Flashpi::APITimeoutError` (Python's
  names) and `Flashpi::WebhookVerificationError`, whose `reason` is a Symbol
  (`:no_matching_signature`). Their fields are readers (`status`, `code`, `title`, `detail`,
  `errors`, `request_id`, `problem`, `headers`, `retry_after`); `idempotency_key` is the only
  one the SDK sets after creating the error. The User-Agent is `flashpi-ruby/<version>`.
- **The client.** `Flashpi::Client.new(api_key:, base_url:, timeout:, max_retries:, language:,
  default_headers:)`, keywords only, each nil for its default. Timeouts are seconds (Integer or
  Float), as in Python. `language` takes a String or a Symbol (`:es`). There is no `http_client`
  option: requests go through net/http, with the proxy of the environment (`https_proxy`,
  `no_proxy`), as net/http reads it; in tests, WebMock or VCR answer in place of the API (the
  transport creates each `Net::HTTP` when it runs, so WebMock's replacement is the one used).
  `inspect` shows the environment and the URL only.
- **Per-call options.** Keywords (`idempotency_key:`, `timeout:`, `max_retries:`, `language:`,
  `correlation_id:`, `extra_headers:`), as Python's keyword arguments. Bodies and list filters are
  a positional hash, as Python's dicts: `documents.list({ status: "authorized" }, timeout: 30)`.
  Without the braces Ruby takes the filters as keywords, so an unknown option raises an
  `ArgumentError` that says the filters go in a hash.
- **Bodies and answers.** A body is serialized once with `JSON.generate`; it may hold Hashes
  (String, Symbol or Integer keys), Arrays, Strings, Symbols, Integers, finite Floats, booleans
  and nil. Anything else (a `BigDecimal`, a `Time`) raises `TypeError`, since amounts and dates
  are text in the API; NaN, text that is not valid UTF-8 (binary strings are read as UTF-8, other
  encodings are converted), a key given twice once keys become text, and a Hash or Array that
  contains itself raise `ArgumentError`. Answers are parsed with Symbol keys, invalid UTF-8
  replaced, up to 512 levels deep. XML answers are UTF-8 text; PDFs are binary Strings.
- **Queries and paths.** Filters whose value is nil are left out; booleans are sent as `true`
  and `false`, Strings, Symbols, Integers and finite Floats as text, Dates as ISO 8601; anything
  else raises `TypeError`. The encoding is `URI.encode_www_form` (a space as `+`), as Python's
  `urlencode`. Path ids are encoded as `encodeURIComponent` does; ids that are not Strings, blank
  ids, `.` and `..` raise `Flashpi::Error`, as in Python.
- **Misused arguments.** What a type checker would refuse raises `TypeError` or `ArgumentError`
  (Python: `TypeError` or `ValueError`): an unknown option, a header name or value, a filter, a
  body, a webhook `tolerance` or `now`, a certificate upload that is not a Hash or a file that is
  neither bytes nor an IO. Bad timeouts, `max_retries`, ids, `base_url` and the API key stay
  `Flashpi::Error`, as in Node and Python.
- **Headers.** Python's rules: every value that becomes a header is checked before anything is
  sent; spaces, tabs and line breaks around a value are trimmed; a control character other than
  a tab, or text that cannot be sent as UTF-8, raises `ArgumentError`; header names are RFC 9110
  tokens, as Strings or Symbols; `Content-Length` and `Transfer-Encoding` are refused; an empty
  language is not sent. A request net/http refuses to build raises a `Flashpi::Error` that is not
  retried and does not quote net/http's reason.
- **with_response.** Each resource's `with_response` view runs the method and returns a
  `Flashpi::APIResponse` with `data`, `status`, `headers` (by lowercase name) and `request_id`,
  instead of Python's `httpx.Response`: net/http's response object is not part of the API. The
  answer is recorded in a fiber-local slot, as Python's ContextVar.
- **Pages.** `list` returns a `Flashpi::Page`, `Enumerable` over every item of every page,
  fetched as needed (`first(10)` fetches only what it needs); `data`, `has_more?`, `next_cursor`,
  `has_next_page?` and `next_page` move one page at a time. Walking a page twice fetches the
  following pages again.
- **The deadline of an attempt.** Before each attempt, net/http's open, read and write timeouts
  are set to the attempt's timeout. Each `Net::HTTP` the SDK creates is extended so that
  connecting and the TLS handshake are limited to the time the attempt has left (its private
  `connect` and `ssl_socket_connect`), and its `on_connect` hook wraps the connection's socket so
  that every read, write and wait keeps the deadline too; the body is checked as each piece
  arrives and once it is read. These hooks reach private methods of net/http, pinned by
  `test/transport_test.rb` on every supported Ruby: if net/http changes them, the per-operation
  timeouts still apply. Only a DNS lookup that net/http cannot interrupt can run past the
  deadline.
- **Connections.** Each client keeps a thread-safe pool of up to 10 idle connections, one
  attempt at a time each; net/http reconnects one that has been idle for 2 seconds or that the
  server closed. After a fork the child drops the parent's connections without closing them
  (closing would end the parent's TLS sessions). `close` closes the idle connections and the
  client stays usable. net/http's own retries are turned off: the SDK's rules are the only ones.
  Redirects are never followed. A POST without a body is sent with `Content-Length: 0` and no
  `Content-Type` (net/http before 0.7 would add `application/x-www-form-urlencoded`). Network
  failures (DNS, refused or reset connections, TLS, a malformed answer, a broken gzip body) are
  `APIConnectionError`s and are retried; timeouts are `APITimeoutError`s.
- **Secrets.** The API key, the request headers, a .p12 and its password live in closures
  (`Flashpi::Internal::Secret`): `inspect`, `pp`, `to_s` and ActiveSupport's `as_json` (which
  reads instance variables) never show them, and `Marshal.dump` refuses them. Ruby's backtraces
  carry no values, but error trackers can record the local variables of the method that raises
  (Sentry's `include_local_variables`, Rollbar's locals), so every error the SDK raises comes from
  a method that holds none of them (the tests check it with a `TracePoint`). net/http's own
  frames, in the cause of a network error, are not changed.
- **Webhooks.** `Flashpi::Webhooks.verify_signature` and `Flashpi::Webhooks.unwrap` (also
  `client.webhooks`, which returns that module), with `tolerance:` and `now:` (a `Time` or Unix
  seconds). Headers can be a Hash in any letter case, a Rack env (`HTTP_WEBHOOK_ID`) or anything
  that yields name and value pairs (Rails' `request.headers`); values may be Arrays. The body
  must be a String (its bytes are signed); anything else is `:invalid_payload`, and a secret that
  is not a String is `:invalid_secret`. Base64 is decoded as `atob`: padding optional, trailing
  bits ignored. `unwrap` returns the event with Symbol keys; a body that is not a JSON object is
  `:invalid_payload`. A `webhook-id` that is not UTF-8 is signed as its bytes (Python and Node
  always end at `:no_matching_signature`). Its RBS type, `Flashpi::Types::webhook_event`, is one
  record with the members every event has (`data` untyped): Steep cannot narrow a union of
  records on `type`, and checking the union made a 20-line Rails controller take over a minute.
  The exact shapes are `document_event`, `certificate_event`, `account_event`,
  `webhook_endpoint_verification_event` and `thin_event`.
- **Certificate uploads.** `{ file:, password:, filename: }` with Symbol or String keys. The file
  is a String of bytes or anything with `read`, read once in pieces up to one byte past 1 MiB (a
  bigger file is refused without being read whole) and not closed. A text-mode file is not
  refused. The body is encoded once (the password field, then the file part, whose content type is
  always `application/x-pkcs12`), so every retry sends the same bytes; the file name is escaped
  as browsers do.
- **Types.** A generator of our own (`scripts/openapi.rb`, standard library only) writes
  `sig/flashpi/types.rbs`: one alias per schema and per list query in `Flashpi::Types`, in
  snake_case (`Document` is `document`, an inline enum `DocumentStatus` is `document_status`),
  records with optional keys, `number` as `Integer | Float`, typed `additionalProperties` as
  `Hash[Symbol, T]`, and the API's descriptions as comments. It fails on any construct it does
  not know. Hand-written types are in `sig/flashpi/sdk_types.rbs`. The signatures of the
  internals ship too, so Steep checks the whole gem in strict mode, and `sig/manifest.yaml` names
  the standard libraries they use. Every resource method's signature lists the per-call options
  as keywords, so a user's Steep checks them; the implementations take `**options`.
- **README examples.** Every ruby block of both READMEs becomes a file in
  `test/examples/readme/` (`scripts/readme.rb`), which Steep checks in strict mode against the
  gem's signatures (the request bodies against the API's types) and RuboCop lints; the tests keep
  them in step with the READMEs, compile them on every supported Ruby and compare the code of the
  two READMEs. The Rails and Sinatra examples are checked against small signatures of the few
  methods they call, so neither framework becomes a dependency.
- **Tooling.** RuboCop with double quotes and lines of up to 120 characters (the metrics of
  method size are off). The coverage gate (95 % of the lines of `lib/`) uses the standard
  library's `Coverage`, not SimpleCov, so no other development gem is needed. `Gemfile.lock` is
  committed, as Bundler now recommends for gems too, with the platforms of CI and macOS and
  Bundler's checksums; the Gemfile lists the tools only, without the gemspec, because Bundler 4
  writes a path gem's version twice in the lockfile and release-please updates only the first.
- **CI.** RuboCop, Steep, the generated types, the README examples and the tests with the
  coverage gate on Ruby 4.0; the tests on Ruby 3.3, 3.4 and 4.0; and the gem built, checked file
  by file (`scripts/package_check.rb`) and installed alone, with no other gem, then used against
  a local server (`scripts/installed_check.rb`) on Ruby 3.3 and 4.0.
- **Releases.** release-please's `ruby` type writes the version to `lib/flashpi/version.rb`. A
  build job, with a read-only token and no secret, builds the tag with `gem build` on an exact
  Ruby (4.0.9, pinned by hand in `release.yml`) without Bundler, and checks it. The publish job,
  the only one with `id-token: write`, checks out nothing and runs no code of the repository or
  of any gem: it downloads the gem and runs `gem push` with a short-lived key from
  `rubygems/configure-rubygems-credentials`. There are no Sigstore attestations yet: RubyGems
  4.0's `gem push` does not make them, and `rubygems/release-gem` makes them by running the
  `sigstore-cli` gem in the publish job. The gemspec requires MFA for pushes
  (`rubygems_mfa_required`; trusted publishing keys pass it) and allows pushes to rubygems.org
  only.
