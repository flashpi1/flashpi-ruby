# Flashpi for Ruby

The official Ruby SDK for [Flashpi](https://flashpi.com.ec), the electronic invoicing API for
Ecuador's SRI.

> **Not published on RubyGems yet.** The first version (0.1.0) is being prepared. Meanwhile, call
> the API over plain HTTP: see the [documentation](https://flashpi.com.ec/docs/en/).

[Español](https://github.com/flashpi1/flashpi-ruby/blob/main/README.md)

- The 45 operations of the API: the six document types, documents (XML, RIDE PDF, email),
  issuers with establishments, emission points and .p12 certificates, webhooks and events.
- One client (`Flashpi::Client`) you can share between threads, which reuses its connections.
- RBS signatures generated from the API's OpenAPI document, so Steep and the editors that read
  RBS know every field.
- Safe retries: every issuing request carries an `Idempotency-Key`, so a retry never issues a
  document twice.
- Typed errors (RFC 9457) with their `code`, field errors and `request_id`.
- Automatic pagination: every list is `Enumerable` and fetches the pages as you go.
- Webhook signature verification (Standard Webhooks) for Rails, Sinatra or any Rack app.
- Ruby 3.3 or later. No dependencies: the standard library only (net/http).

## Install

```bash
bundle add flashpi
```

Or without Bundler: `gem install flashpi`.

## Getting started

Create an API key in the [console](https://flashpi.com.ec/app/) and keep it in the
`FLASHPI_API_KEY` environment variable. An `fp_test_` key issues in the SRI's test environment;
an `fp_live_` key issues real documents in production.

```ruby
require "flashpi"

# Reads FLASHPI_API_KEY; you can also pass it: Flashpi::Client.new(api_key: "fp_test_...")
flashpi = Flashpi::Client.new

invoice = flashpi.invoices.create(
  {
    issuerId: "<the demo issuer id or yours>",
    establishment: "001",
    emissionPoint: "001",
    customer: {
      idType: "ruc",
      id: "1760013210001",
      name: "PRUEBAS SERVICIO DE RENTAS INTERNAS",
      address: "Av. Amazonas y Villalengua, Quito"
    },
    items: [
      {
        code: "P-001",
        description: "Test service",
        quantity: "1",
        unitPrice: "1.00",
        taxes: [{ type: "vat", rate: "15" }]
      }
    ],
    payments: [{ method: "cash", amount: "1.15" }],
    options: { waitForAuthorization: true }
  }
)

puts invoice[:status], invoice[:accessKey]
```

Requests and answers are hashes with the API's own keys, in camelCase, as symbols
(`invoice[:accessKey]`), typed in `Flashpi::Types` (`Flashpi::Types::create_invoice`,
`Flashpi::Types::document`). Amounts and quantities are **strings** (`"1.15"`), never numbers, so
no decimals are lost. Write the body in braces, `create({ ... })`: without them, Ruby would take
it as the options of the call.

With the **demo issuer** you can issue test documents without uploading a certificate: its id is
on the console's Overview (up to 50 documents a day). See
[Sandbox and demo issuer](https://flashpi.com.ec/docs/en/sandbox/).

A client keeps its connections open for the next requests and can be shared between threads:
create one and reuse it (in Rails, for example, in an initializer). `flashpi.close` closes those
connections.

## Issuing documents

| Document                                    | Method                                      |
| ------------------------------------------- | ------------------------------------------- |
| Invoice (factura)                           | `flashpi.invoices.create(body)`             |
| Credit note (nota de crédito)               | `flashpi.credit_notes.create(body)`         |
| Debit note (nota de débito)                 | `flashpi.debit_notes.create(body)`          |
| Purchase settlement (liquidación de compra) | `flashpi.purchase_settlements.create(body)` |
| Waybill (guía de remisión)                  | `flashpi.waybills.create(body)`             |
| Withholding (comprobante de retención)      | `flashpi.withholdings.create(body)`         |

They all return the document. By default the answer comes right away with the status
`processing`, and the SRI's outcome arrives by webhook. With
`options: { waitForAuthorization: true }` the API waits for the SRI (15 s by default, up to 30 s
with `waitTimeoutSeconds`) and returns `authorized`, `rejected` or `failed`; if the SRI takes
longer, it returns `processing` or `pending_sri` and the document carries on.

## Documents

```ruby
document = flashpi.documents.get(invoice[:id])
puts document[:status]

xml = flashpi.documents.xml(invoice[:id]) # xml[:kind]: "authorized" once the SRI authorized it
pdf = flashpi.documents.pdf(invoice[:id]) # the RIDE, as bytes
File.binwrite("#{invoice[:accessKey]}.pdf", pdf)
puts xml[:xml] if xml[:kind] == "authorized"

flashpi.documents.send_email(invoice[:id]) # emails the RIDE and the XML to the buyer again
```

## Lists and pagination

A list call returns a page that is `Enumerable`: `each` walks every page, fetching them as you
go, and `first(10)` fetches only the pages it needs.

```ruby
flashpi.documents.list({ status: "authorized", issueDateFrom: "2026-11-01" }).each do |document|
  puts document[:accessKey]
end

page = flashpi.documents.list({ limit: 50 })
puts page.data.size # the documents of this page
page = page.next_page if page.has_next_page?
```

The filters use the API's names (`issueDateFrom`, `issuerId`) and go in a hash in braces, before
the options of the call.

## Errors

Every API error is a subclass of `Flashpi::APIError` by HTTP status. Branch on `code`, which is
stable and in English; `message` follows the requested language.

```ruby
begin
  flashpi.invoices.create(body)
rescue Flashpi::UnprocessableEntityError => e
  puts e.code # "validation_failed", "total_mismatch", ...
  e.errors.each { |field| puts "#{field[:field]}: #{field[:message]}" }
  raise
rescue Flashpi::APIError => e
  puts e.status, e.code, e.request_id # share request_id with support
  raise
end
```

| Class                               | Status | Examples of `code`                                          |
| ----------------------------------- | ------ | ----------------------------------------------------------- |
| `Flashpi::BadRequestError`          | 400    | `malformed_json`, `invalid_idempotency_key`                 |
| `Flashpi::AuthenticationError`      | 401    | `authentication_required`, `invalid_api_key`                |
| `Flashpi::PermissionDeniedError`    | 403    | `key_read_only`, `key_scope_mismatch`, `ip_not_allowed`     |
| `Flashpi::NotFoundError`            | 404    | `not_found`                                                 |
| `Flashpi::ConflictError`            | 409    | `sequential_already_used`, `ride_not_available`             |
| `Flashpi::UnprocessableEntityError` | 422    | `validation_failed`, `total_mismatch`                       |
| `Flashpi::RateLimitError`           | 429    | `demo_issuer_quota_exceeded`, `account_email_limit_reached` |
| `Flashpi::InternalServerError`      | 5xx    | `internal_error`                                            |
| `Flashpi::APIConnectionError`       | —      | no answer (network); `APITimeoutError` when it timed out    |

They all extend `Flashpi::Error`. Some errors carry extra data in `error.problem`, such as
`documentId`, `limit`, `resetsAt` or `rideStatus`. For messages in Spanish:
`Flashpi::Client.new(language: "es")`.

## Retries and idempotency

The SDK retries network errors, timeouts, and 408, 429 and 5xx answers (when they ask to wait
60 s or less; not 501 nor `demo_issuer_unavailable`) up to 2 times, with growing waits. Every POST
carries an `Idempotency-Key` that its retries repeat, so the API never issues twice:

- When a retry finds that the first attempt did create the document, the SDK returns that
  document.
- When the first attempt is still running on the API (for example, the connection dropped while
  it waited for the SRI), the SDK waits for it with the same key, up to the call's time limit,
  without using up retries.

To use your own key (for example your order id), pass it to the call:

```ruby
flashpi.invoices.create(body, idempotency_key: "order-#{order.id}")
```

If issuing still fails, the error (a `Flashpi::Error`) carries the key it used in
`error.idempotency_key`. Trying again with `idempotency_key: error.idempotency_key` never issues
a second document: within 24 hours the API returns the first answer again; after that (or if the
API lost track of the first attempt), the call fails with a 422 `idempotency_key_reused` whose
`error.problem[:documentId]` is the existing document (read it with `flashpi.documents.get`).

```ruby
begin
  flashpi.invoices.create(body)
rescue Flashpi::Error => e
  save_for_retry(body, e.idempotency_key) if e.idempotency_key # your retry queue
  raise
end
```

A call you interrupt from outside (with `Timeout.timeout`, or by stopping the process or the
thread) raises no `Flashpi::Error` and has no key: if you do that to issuing calls, pass your own
`idempotency_key`.

Daily limits (such as the demo issuer's quota) are not retried: they are raised as a
`Flashpi::RateLimitError` with `retry_after` in seconds.

## Webhooks

Verify every webhook with the body **exactly as it arrived** (not parsed) and the endpoint's
`whsec_` secret. `Flashpi::Webhooks.unwrap` needs no API key (it is also `flashpi.webhooks`). It
takes the headers as a hash, a Rack `env` or Rails' `request.headers`.

With Rails:

```ruby
class FlashpiWebhooksController < ApplicationController
  skip_forgery_protection

  def create
    event = Flashpi::Webhooks.unwrap(request.raw_post, request.headers, ENV.fetch("FLASHPI_WEBHOOK_SECRET"))

    case event[:type]
    when "webhook_endpoint.verification"
      # The endpoint's activation: answer the challenge.
      return render(json: { challenge: event[:data][:challenge] })
    when "invoice.authorized"
      Rails.logger.info("Authorized #{event[:data][:accessKey]}") # event[:data] is the document
    when "invoice.rejected"
      Rails.logger.info("Rejected #{event[:data][:sriMessages]}")
    end
    head :no_content
  rescue Flashpi::WebhookVerificationError
    head :bad_request
  end
end
```

With Sinatra (or any Rack app, with its `env`):

```ruby
require "sinatra"
require "flashpi"

post "/webhooks/flashpi" do
  event = Flashpi::Webhooks.unwrap(request.body.read, request.env, ENV.fetch("FLASHPI_WEBHOOK_SECRET"))
  if event[:type] == "webhook_endpoint.verification"
    content_type :json
    JSON.generate({ challenge: event[:data][:challenge] })
  else
    handle_event(event) # your code, like the branches of the Rails example
    204
  end
rescue Flashpi::WebhookVerificationError
  400
end
```

Store `event[:id]` and drop repeats: an event may arrive more than once. During a secret
rotation Flashpi signs with both the new and the previous secret, so either one works. If the
endpoint uses the `thin` mode (no `data`), read the event with `flashpi.events.get(event[:id])`.

## Issuers and certificates

These operations need an account-wide key with read and write access.

An issuer starts from its electronic signature (.p12): Flashpi checks it, reads the RUC and asks
the SRI, and returns a `prefill` with what it found so you can build the issuer.

```ruby
onboarding = flashpi.issuer_onboardings.create(
  { file: File.binread("firma.p12"), password: ENV.fetch("P12_PASSWORD") }
)
while onboarding[:status] == "verifying"
  sleep 2
  onboarding = flashpi.issuer_onboardings.get(onboarding[:id])
end
unless onboarding[:status] == "ready"
  rejection = onboarding[:rejection]
  raise(rejection ? rejection[:message] : onboarding[:status])
end

prefill = onboarding[:prefill]
completed =
  if onboarding[:existingIssuer]
    # You already have that RUC: the certificate is added to that issuer (a renewal).
    flashpi.issuer_onboardings.complete(onboarding[:id])
  else
    # A new RUC: you confirm the issuer's data, starting from the prefill.
    tax_profile = prefill && prefill[:taxProfile]
    rimpe_regime = tax_profile && tax_profile[:rimpeRegime]
    flashpi.issuer_onboardings.complete(
      onboarding[:id],
      {
        legalName: (prefill && prefill[:legalName]) || "MY COMPANY S.A.",
        headOfficeAddress: (prefill && prefill[:headOfficeAddress]) || "Av. Amazonas N24-100, Quito",
        taxProfile: {
          keepsAccounting: tax_profile ? tax_profile[:keepsAccounting] == true : false,
          # The RIMPE regime, if any ("general" is not one).
          rimpeRegime: case rimpe_regime when "entrepreneur", "popular_business" then rimpe_regime end
          # For a special taxpayer or a withholding agent, add their resolutions.
        }
        # When onboarding[:rucNeedsConfirmation] is true, send ruc: too.
      }
    )
  end

flashpi.issuers.establishments.list(completed[:issuer][:id]).each do |establishment|
  puts establishment[:code]
end
```

The `file` can be the bytes of the .p12 (`File.binread("firma.p12")`) or a file opened in binary
mode (`File.open("firma.p12", "rb")`), up to 1 MiB.

To **renew an issuer's signature** for test and live mode at once, run the same flow with the
new .p12: Flashpi recognizes the RUC (`existingIssuer`) and `complete` with no data adds the
certificate. `flashpi.issuers.certificates.upload(issuer_id, { file: ..., password: ... })`,
instead, uploads a certificate for the mode of the key you use only (test or live).

## Options

```ruby
flashpi = Flashpi::Client.new(
  api_key: ENV.fetch("FLASHPI_API_KEY"), # defaults to the FLASHPI_API_KEY variable
  language: "es", # language of the messages: "en" (default) or "es"
  timeout: 60, # seconds per attempt (at least the SRI wait + 15 s with waitForAuthorization)
  max_retries: 2 # 0 turns retries off
)
```

Every method also takes the options of that request as keyword arguments: `idempotency_key`,
`timeout`, `max_retries`, `language`, `correlation_id` (your own id, which Flashpi logs) and
`extra_headers`.

```ruby
document = flashpi.documents.get(document_id, timeout: 10, language: "es", correlation_id: "order-42")
```

To see the HTTP answer and the request id, call the method through `with_response`:

```ruby
result = flashpi.documents.with_response.get(document_id)
puts result.data[:status], result.status, result.request_id
```

The timeout is one deadline per attempt, from sending it to reading the whole answer: connecting,
the TLS handshake and every read and write count against it (only the DNS lookup can run past
it). Requests go out through net/http with the proxy of the environment variables
(`https_proxy`, `no_proxy`), and the SDK never follows redirects. In your tests, WebMock or VCR
can answer in place of the API.

## Types

The gem ships its RBS signatures in `sig/`. With [Steep](https://github.com/soutaro/steep),
`rbs collection install` finds them through your `Gemfile.lock`, and Steep checks the names of
the fields, their possible values and the options of every call. The signatures need rbs 3.5 or
later (Steep 1.7 or later); Ruby 3.3 comes with rbs 3.4.

```ruby
# @type var body: Flashpi::Types::create_invoice
body = {
  issuerId: "<the issuer id>",
  establishment: "001",
  emissionPoint: "001",
  customer: { idType: "final_consumer" },
  items: [{ description: "Bread", quantity: "2", unitPrice: "0.50", taxes: [{ type: "vat", rate: "15" }] }],
  payments: [{ method: "cash", amount: "1.15" }]
}
document = flashpi.invoices.create(body) # Flashpi::Types::document
puts document[:accessKey]
```

## Servers only

Your API key is a secret: use the SDK on your servers, never in code that runs on your users'
devices. `flashpi.inspect` shows the environment and the URL, never the key.

## License

[MIT](https://github.com/flashpi1/flashpi-ruby/blob/main/LICENSE) © 2026 SIGNIADIGITAL S.A.
