# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "time"
require "uri"
require "zlib"

require_relative "flashpi/version"
require_relative "flashpi/errors"
require_relative "flashpi/api_response"
require_relative "flashpi/page"
require_relative "flashpi/internal/secret"
require_relative "flashpi/internal/validate"
require_relative "flashpi/internal/json_text"
require_relative "flashpi/internal/problems"
require_relative "flashpi/internal/request"
require_relative "flashpi/internal/multipart"
require_relative "flashpi/internal/transport"
require_relative "flashpi/internal/engine"
require_relative "flashpi/internal/resource"
require_relative "flashpi/internal/settings"
require_relative "flashpi/resources/documents"
require_relative "flashpi/resources/issuers"
require_relative "flashpi/resources/issuer_onboardings"
require_relative "flashpi/resources/webhook_endpoints"
require_relative "flashpi/resources/events"
require_relative "flashpi/webhooks"
require_relative "flashpi/client"

# The official Ruby SDK for Flashpi, the electronic invoicing API for Ecuador's SRI.
#
#   require "flashpi"
#
#   flashpi = Flashpi::Client.new # reads FLASHPI_API_KEY
#   invoice = flashpi.invoices.create({ issuerId: "...", ... })
#   invoice[:accessKey]
module Flashpi
end
