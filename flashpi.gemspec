# frozen_string_literal: true

require_relative "lib/flashpi/version"

Gem::Specification.new do |spec|
  spec.name = "flashpi"
  spec.version = Flashpi::VERSION
  spec.authors = ["SIGNIADIGITAL S.A."]
  spec.summary = "The official Ruby SDK for Flashpi, the electronic invoicing API for Ecuador's SRI."
  spec.description = <<~TEXT.tr("\n", " ").strip
    Issue invoices, credit and debit notes, purchase settlements, waybills and withholding
    receipts with Ecuador's SRI through the Flashpi API, manage issuers and their .p12
    certificates, and verify Flashpi's webhooks. No runtime dependencies.
  TEXT
  spec.homepage = "https://flashpi.com.ec"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "homepage_uri" => "https://flashpi.com.ec",
    "documentation_uri" => "https://flashpi.com.ec/docs/sdks/",
    "source_code_uri" => "https://github.com/flashpi1/flashpi-ruby",
    "bug_tracker_uri" => "https://github.com/flashpi1/flashpi-ruby/issues",
    "changelog_uri" => "https://github.com/flashpi1/flashpi-ruby/blob/main/CHANGELOG.md",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }

  # The library, its RBS signatures and the documents a user reads; tests and tooling stay in
  # the repository.
  spec.files = Dir.glob(%w[lib/**/*.rb sig/**/*.rbs sig/manifest.yaml]) +
               %w[LICENSE README.md README.en.md CHANGELOG.md].select { |file| File.file?(File.join(__dir__, file)) }
  spec.require_paths = ["lib"]
end
