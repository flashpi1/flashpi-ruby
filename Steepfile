# frozen_string_literal: true

D = Steep::Diagnostic

# The gem: lib checked against its RBS signatures in sig/.
target :lib do
  signature "sig"
  check "lib"

  library "net-http", "net-protocol", "openssl", "json", "securerandom", "uri", "time", "date", "zlib", "socket",
          "timeout"

  configure_code_diagnostics(D::Ruby.strict) do |hash|
    # The resource methods take the per-call options as `**options`; their signatures list each
    # option as a keyword, so that the code of the gem's users is checked.
    hash[D::Ruby::DifferentMethodParameterKind] = nil
  end
end

# The README examples (test/examples/readme, from `ruby scripts/readme.rb generate`): the code a
# user of the gem writes, checked against the gem's signatures, with the request bodies against
# the API's types. test/examples/sig declares what they take from earlier blocks and frameworks.
target :examples do
  signature "sig", "test/examples/sig"
  check "test/examples/readme"

  library "net-http", "net-protocol", "openssl", "json", "securerandom", "uri", "time", "date", "zlib", "socket",
          "timeout", "logger", "stringio"

  configure_code_diagnostics(D::Ruby.strict)
end
