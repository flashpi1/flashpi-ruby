# frozen_string_literal: true

LIB = File.expand_path("../lib", __dir__)

# COVERAGE=95 measures the lines of lib/ and fails the run below that percentage. It starts
# before the gem is loaded, and its report runs after the tests (at_exit runs in reverse order).
if ENV.fetch("COVERAGE", "") != ""
  require "coverage"
  Coverage.start(lines: true)
  at_exit do
    minimum = Float(ENV.fetch("COVERAGE"))
    files = Coverage.result.select { |path, _| path.start_with?("#{LIB}/") }
    covered = relevant = 0
    missed = []
    files.sort.each do |path, data|
      lines = data.fetch(:lines)
      relevant += lines.compact.size
      covered += lines.count { |hits| hits&.positive? }
      gaps = lines.each_index.select { |index| lines[index]&.zero? }.map { |index| index + 1 }
      missed << "#{path.delete_prefix("#{LIB}/")}: #{gaps.join(", ")}" unless gaps.empty?
    end
    percent = relevant.zero? ? 0.0 : (covered * 100.0 / relevant)
    puts "\nLine coverage of lib/: #{percent.round(2)} % (#{covered} of #{relevant} lines)"
    puts("Lines not run:", missed.map { |line| "  #{line}" }) unless missed.empty?
    if percent < minimum
      warn "Coverage is below #{minimum} %"
      exit 1
    end
  end
end

$LOAD_PATH.unshift(LIB)
require "flashpi"
require "minitest/autorun"
require_relative "support/fakes"
require_relative "support/local_server"
