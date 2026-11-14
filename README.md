# Flashpi para Ruby

SDK oficial de [Flashpi](https://flashpi.com.ec), la API de facturación electrónica del SRI de
Ecuador, para Ruby.

> **Aún no está publicado en RubyGems.** La primera versión (0.1.0) está en preparación. Mientras
> tanto puedes usar la API con HTTP simple: consulta la
> [documentación](https://flashpi.com.ec/docs/).

[English](https://github.com/flashpi1/flashpi-ruby/blob/main/README.en.md)

- Las 45 operaciones de la API: los seis comprobantes, documentos (XML, RIDE en PDF, correo),
  emisores con establecimientos, puntos de emisión y certificados .p12, webhooks y eventos.
- Un cliente (`Flashpi::Client`) que puedes compartir entre hilos y que reutiliza sus conexiones.
- Firmas RBS generadas del documento OpenAPI de la API: Steep y los editores que leen RBS conocen
  cada campo.
- Reintentos seguros: cada emisión lleva un `Idempotency-Key`, así un reintento nunca emite dos
  veces.
- Errores tipados (RFC 9457) con su `code`, los errores por campo y el `request_id`.
- Paginación automática: cada lista es `Enumerable` y pide las páginas a medida que avanzas.
- Verificación de firmas de webhooks (Standard Webhooks) para Rails, Sinatra o cualquier app Rack.
- Ruby 3.3 o superior. Sin dependencias: solo la biblioteca estándar (net/http).

## Instalación

```bash
bundle add flashpi
```

O sin Bundler: `gem install flashpi`.

## Primeros pasos

Crea una clave de API en la [consola](https://flashpi.com.ec/app/) y guárdala en la variable de
entorno `FLASHPI_API_KEY`. Una clave `fp_test_` emite en el ambiente de pruebas del SRI; una
`fp_live_` emite comprobantes reales en producción.

```ruby
require "flashpi"

# Lee FLASHPI_API_KEY; también puedes pasarla: Flashpi::Client.new(api_key: "fp_test_...")
flashpi = Flashpi::Client.new

invoice = flashpi.invoices.create(
  {
    issuerId: "<id del emisor demo o del tuyo>",
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
        description: "Servicio de prueba",
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

Las peticiones y las respuestas son hashes con las claves de la API en camelCase, como símbolos
(`invoice[:accessKey]`), con sus tipos en `Flashpi::Types` (`Flashpi::Types::create_invoice`,
`Flashpi::Types::document`). Los montos y cantidades son **textos** (`"1.15"`), nunca números,
para no perder decimales. Escribe el cuerpo entre llaves, `create({ ... })`: sin ellas, Ruby lo
tomaría como opciones de la llamada.

Con el **emisor demo** puedes emitir en pruebas sin subir un certificado: su id está en el
Resumen de la consola (hasta 50 comprobantes al día). Más en
[Sandbox y emisor demo](https://flashpi.com.ec/docs/sandbox/).

Un cliente mantiene abiertas sus conexiones para las siguientes peticiones y se puede compartir
entre hilos: crea uno y reutilízalo (en Rails, por ejemplo, en un initializer). `flashpi.close`
cierra esas conexiones.

## Emitir comprobantes

| Comprobante           | Método                                      |
| --------------------- | ------------------------------------------- |
| Factura               | `flashpi.invoices.create(body)`             |
| Nota de crédito       | `flashpi.credit_notes.create(body)`         |
| Nota de débito        | `flashpi.debit_notes.create(body)`          |
| Liquidación de compra | `flashpi.purchase_settlements.create(body)` |
| Guía de remisión      | `flashpi.waybills.create(body)`             |
| Retención             | `flashpi.withholdings.create(body)`         |

Todos devuelven el documento. Por defecto la respuesta llega enseguida con el estado
`processing` y el resultado del SRI llega por webhook. Con
`options: { waitForAuthorization: true }` la API espera la respuesta del SRI (15 s por defecto,
hasta 30 s con `waitTimeoutSeconds`) y devuelve `authorized`, `rejected` o `failed`; si el SRI
tarda más, devuelve `processing` o `pending_sri` y el documento sigue su curso.

## Documentos

```ruby
document = flashpi.documents.get(invoice[:id])
puts document[:status]

xml = flashpi.documents.xml(invoice[:id]) # xml[:kind]: "authorized" cuando ya lo autorizó el SRI
pdf = flashpi.documents.pdf(invoice[:id]) # el RIDE, en bytes
File.binwrite("#{invoice[:accessKey]}.pdf", pdf)
puts xml[:xml] if xml[:kind] == "authorized"

flashpi.documents.send_email(invoice[:id]) # reenvía RIDE y XML al correo del comprador
```

## Listas y paginación

Una lista devuelve una página que es `Enumerable`: `each` recorre todas las páginas, que se
piden a medida que avanzas, y `first(10)` solo pide las que necesita.

```ruby
flashpi.documents.list({ status: "authorized", issueDateFrom: "2026-11-01" }).each do |document|
  puts document[:accessKey]
end

page = flashpi.documents.list({ limit: 50 })
puts page.data.size # los documentos de esta página
page = page.next_page if page.has_next_page?
```

Los filtros usan los nombres de la API (`issueDateFrom`, `issuerId`) y van en un hash entre
llaves, antes de las opciones de la llamada.

## Errores

Cada error de la API es una subclase de `Flashpi::APIError` según su estado HTTP. Decide según
`code`, que es estable y en inglés; `message` sigue el idioma pedido.

```ruby
begin
  flashpi.invoices.create(body)
rescue Flashpi::UnprocessableEntityError => e
  puts e.code # "validation_failed", "total_mismatch", ...
  e.errors.each { |field| puts "#{field[:field]}: #{field[:message]}" }
  raise
rescue Flashpi::APIError => e
  puts e.status, e.code, e.request_id # comparte request_id con soporte
  raise
end
```

| Clase                               | Estado | Ejemplos de `code`                                          |
| ----------------------------------- | ------ | ----------------------------------------------------------- |
| `Flashpi::BadRequestError`          | 400    | `malformed_json`, `invalid_idempotency_key`                 |
| `Flashpi::AuthenticationError`      | 401    | `authentication_required`, `invalid_api_key`                |
| `Flashpi::PermissionDeniedError`    | 403    | `key_read_only`, `key_scope_mismatch`, `ip_not_allowed`     |
| `Flashpi::NotFoundError`            | 404    | `not_found`                                                 |
| `Flashpi::ConflictError`            | 409    | `sequential_already_used`, `ride_not_available`             |
| `Flashpi::UnprocessableEntityError` | 422    | `validation_failed`, `total_mismatch`                       |
| `Flashpi::RateLimitError`           | 429    | `demo_issuer_quota_exceeded`, `account_email_limit_reached` |
| `Flashpi::InternalServerError`      | 5xx    | `internal_error`                                            |
| `Flashpi::APIConnectionError`       | —      | sin respuesta (red); `APITimeoutError` si se agotó el plazo |

Todas derivan de `Flashpi::Error`. Algunos errores traen datos extra en `error.problem`, por
ejemplo `documentId`, `limit`, `resetsAt` o `rideStatus`. Para recibir los mensajes en español:
`Flashpi::Client.new(language: "es")`.

## Reintentos e idempotencia

El SDK reintenta hasta 2 veces, con espera creciente, los errores de red, los tiempos agotados,
las respuestas 408, 429 (si piden esperar 60 s o menos) y 5xx. Cada POST lleva un
`Idempotency-Key` que se repite en sus reintentos, así que la API nunca emite dos veces:

- Si un reintento descubre que el primer intento sí creó el documento, el SDK devuelve ese
  documento.
- Si el primer intento sigue en curso en la API (por ejemplo, se cortó la conexión mientras
  esperaba al SRI), el SDK espera a que termine con la misma clave, hasta el tiempo límite de la
  llamada, sin gastar reintentos.

Para usar tu propia clave (por ejemplo el id de tu pedido), pásala a la llamada:

```ruby
flashpi.invoices.create(body, idempotency_key: "pedido-#{order.id}")
```

Si una emisión falla igual, el error (un `Flashpi::Error`) trae la clave que usó en
`error.idempotency_key`. Reintentar con `idempotency_key: error.idempotency_key` nunca emite un
segundo documento: dentro de 24 horas la API devuelve la primera respuesta; después (o si la API
perdió el primer intento), la llamada falla con un 422 `idempotency_key_reused` cuyo
`error.problem[:documentId]` es el documento que ya existe (léelo con `flashpi.documents.get`).

```ruby
begin
  flashpi.invoices.create(body)
rescue Flashpi::Error => e
  save_for_retry(body, e.idempotency_key) if e.idempotency_key # tu cola de reintentos
  raise
end
```

Una llamada que interrumpes desde fuera (con `Timeout.timeout`, o al detener el proceso o el
hilo) no lanza un `Flashpi::Error` ni trae la clave: si lo haces con emisiones, pasa tu propio
`idempotency_key`.

Los límites diarios (como la cuota del emisor demo) no se reintentan: se lanzan como
`Flashpi::RateLimitError` con `retry_after` en segundos.

## Webhooks

Verifica cada webhook con el cuerpo **tal cual llegó** (sin parsear) y el secreto `whsec_` del
endpoint. `Flashpi::Webhooks.unwrap` no necesita clave de API (también está en
`flashpi.webhooks`). Acepta las cabeceras como un hash, el `env` de Rack o `request.headers` de
Rails.

Con Rails:

```ruby
class FlashpiWebhooksController < ApplicationController
  skip_forgery_protection

  def create
    event = Flashpi::Webhooks.unwrap(request.raw_post, request.headers, ENV.fetch("FLASHPI_WEBHOOK_SECRET"))

    case event[:type]
    when "webhook_endpoint.verification"
      # La activación del endpoint: responde el desafío.
      return render(json: { challenge: event[:data][:challenge] })
    when "invoice.authorized"
      Rails.logger.info("Autorizada #{event[:data][:accessKey]}") # event[:data] es el documento
    when "invoice.rejected"
      Rails.logger.info("Rechazada #{event[:data][:sriMessages]}")
    end
    head :no_content
  rescue Flashpi::WebhookVerificationError
    head :bad_request
  end
end
```

Con Sinatra (o cualquier app Rack, con su `env`):

```ruby
require "sinatra"
require "flashpi"

post "/webhooks/flashpi" do
  event = Flashpi::Webhooks.unwrap(request.body.read, request.env, ENV.fetch("FLASHPI_WEBHOOK_SECRET"))
  if event[:type] == "webhook_endpoint.verification"
    content_type :json
    JSON.generate({ challenge: event[:data][:challenge] })
  else
    handle_event(event) # tu código, como las ramas del ejemplo de Rails
    204
  end
rescue Flashpi::WebhookVerificationError
  400
end
```

Guarda el `event[:id]` y descarta los repetidos: un evento puede llegar más de una vez. Durante
una rotación del secreto, Flashpi firma con el nuevo y el anterior, así que cualquiera de los dos
sirve. Si el endpoint usa el modo `thin` (sin `data`), pide el evento con
`flashpi.events.get(event[:id])`.

## Emisores y certificados

Estas operaciones necesitan una clave de toda la cuenta con acceso de lectura y escritura.

Un emisor nace de su firma electrónica (.p12): Flashpi la verifica, lee el RUC y consulta al SRI,
y te devuelve un `prefill` con lo que encontró para que armes el emisor.

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
    # Ya tienes ese RUC: el certificado se agrega a ese emisor (una renovación).
    flashpi.issuer_onboardings.complete(onboarding[:id])
  else
    # Un RUC nuevo: tú confirmas los datos del emisor, partiendo del prefill.
    tax_profile = prefill && prefill[:taxProfile]
    rimpe_regime = tax_profile && tax_profile[:rimpeRegime]
    flashpi.issuer_onboardings.complete(
      onboarding[:id],
      {
        legalName: (prefill && prefill[:legalName]) || "MI EMPRESA S.A.",
        headOfficeAddress: (prefill && prefill[:headOfficeAddress]) || "Av. Amazonas N24-100, Quito",
        taxProfile: {
          keepsAccounting: tax_profile ? tax_profile[:keepsAccounting] == true : false,
          # El régimen RIMPE, si lo tiene ("general" no es uno).
          rimpeRegime: case rimpe_regime when "entrepreneur", "popular_business" then rimpe_regime end
          # Si es contribuyente especial o agente de retención, agrega sus resoluciones.
        }
        # Si onboarding[:rucNeedsConfirmation] es true, envía también ruc:.
      }
    )
  end

flashpi.issuers.establishments.list(completed[:issuer][:id]).each do |establishment|
  puts establishment[:code]
end
```

El `file` puede ser el contenido del .p12 (`File.binread("firma.p12")`) o un archivo abierto en
modo binario (`File.open("firma.p12", "rb")`), de hasta 1 MiB.

Para **renovar la firma** de un emisor, para pruebas y producción a la vez, repite el mismo
flujo con el .p12 nuevo: Flashpi reconoce el RUC (`existingIssuer`) y `complete` sin datos
agrega el certificado. En cambio,
`flashpi.issuers.certificates.upload(issuer_id, { file: ..., password: ... })` sube un
certificado solo para el modo de la clave que usas (pruebas o producción).

## Opciones

```ruby
flashpi = Flashpi::Client.new(
  api_key: ENV.fetch("FLASHPI_API_KEY"), # por defecto, la variable FLASHPI_API_KEY
  language: "es", # idioma de los mensajes: "en" (por defecto) o "es"
  timeout: 60, # segundos por intento (con waitForAuthorization, al menos la espera + 15 s)
  max_retries: 2 # 0 desactiva los reintentos
)
```

Cada método acepta además, como argumentos con nombre, opciones de esa petición:
`idempotency_key`, `timeout`, `max_retries`, `language`, `correlation_id` (tu propio id, que
Flashpi registra) y `extra_headers`.

```ruby
document = flashpi.documents.get(document_id, timeout: 10, language: "es", correlation_id: "pedido-42")
```

Para ver la respuesta HTTP y el id de la petición, llama al método a través de `with_response`:

```ruby
result = flashpi.documents.with_response.get(document_id)
puts result.data[:status], result.status, result.request_id
```

El tiempo límite es uno solo por intento, desde que se envía hasta que se lee toda la respuesta:
conectar, el saludo TLS y cada lectura y escritura cuentan contra él (solo la consulta DNS puede
pasarse). Las peticiones salen por net/http con el proxy de las variables de entorno
(`https_proxy`, `no_proxy`), y el SDK nunca sigue redirecciones. En tus pruebas, WebMock o VCR
pueden responder en lugar de la API.

## Tipos

El gem trae sus firmas RBS en `sig/`. Con [Steep](https://github.com/soutaro/steep),
`rbs collection install` las encuentra en tu `Gemfile.lock`, y Steep revisa los nombres de los
campos, sus valores posibles y las opciones de cada llamada:

```ruby
# @type var body: Flashpi::Types::create_invoice
body = {
  issuerId: "<id del emisor>",
  establishment: "001",
  emissionPoint: "001",
  customer: { idType: "final_consumer" },
  items: [{ description: "Pan", quantity: "2", unitPrice: "0.50", taxes: [{ type: "vat", rate: "15" }] }],
  payments: [{ method: "cash", amount: "1.15" }]
}
document = flashpi.invoices.create(body) # Flashpi::Types::document
puts document[:accessKey]
```

## Solo en el servidor

Tu clave de API es secreta: usa el SDK en tus servidores, nunca en código que corre en los
dispositivos de tus usuarios. `flashpi.inspect` muestra el ambiente y la URL, nunca la clave.

## Licencia

[MIT](https://github.com/flashpi1/flashpi-ruby/blob/main/LICENSE) © 2026 SIGNIADIGITAL S.A.
