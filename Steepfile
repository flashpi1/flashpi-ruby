# frozen_string_literal: true

D = Steep::Diagnostic

# The gem: lib checked against its RBS signatures in sig/.
target :lib do
  signature "sig"
  check "lib"

  library "net-http", "net-protocol", "openssl", "json", "securerandom", "uri", "time", "date", "zlib", "socket", "timeout"

  configure_code_diagnostics(D::Ruby.strict) do |hash|
    # The resource methods take the per-call options as `**options`; their signatures list each
    # option as a keyword, so that the code of the gem's users is checked.
    hash[D::Ruby::DifferentMethodParameterKind] = nil
  end
end
