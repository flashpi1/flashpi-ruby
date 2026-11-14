# frozen_string_literal: true

# Checks a built gem file by file before it is published:
#
#   gem build flashpi.gemspec
#   ruby scripts/package_check.rb flashpi-0.1.0.gem [v0.1.0]
#
# It fails when the gem misses a file of lib/ or sig/, carries anything else than those, the
# license and the READMEs (and the CHANGELOG once there is one), has a runtime dependency, or does
# not match the version of lib/flashpi/version.rb (and of the tag, when one is given).

require "rubygems/package"

# The checks of a built gem.
module PackageCheck
  ROOT = File.expand_path("..", __dir__)
  DOCUMENTS = %w[LICENSE README.md README.en.md].freeze

  module_function

  def expected_files
    Dir.chdir(ROOT) do
      files = Dir.glob(%w[lib/**/*.rb sig/**/*.rbs sig/manifest.yaml]) + DOCUMENTS
      files << "CHANGELOG.md" if File.file?("CHANGELOG.md")
      files.sort
    end
  end

  def version
    File.read(File.join(ROOT, "lib", "flashpi", "version.rb"))[/VERSION = "([^"]+)"/, 1]
  end

  def problems(path, tag)
    spec = Gem::Package.new(path).spec
    found = []
    missing = expected_files - spec.files
    extra = spec.files - expected_files
    found << "missing files: #{missing.join(", ")}" unless missing.empty?
    found << "unexpected files: #{extra.join(", ")}" unless extra.empty?
    found << "runtime dependencies: #{spec.runtime_dependencies.join(", ")}" unless spec.runtime_dependencies.empty?
    found << "the gem is #{spec.version}, lib/flashpi/version.rb says #{version}" unless spec.version.to_s == version
    found << "the gem is #{spec.version}, the tag is #{tag}" if tag && tag.delete_prefix("v") != spec.version.to_s
    found << "the name is #{spec.name}" unless spec.name == "flashpi"
    found << "the license is #{spec.licenses.inspect}" unless spec.licenses == ["MIT"]
    found << "it needs Ruby #{spec.required_ruby_version}" unless spec.required_ruby_version.to_s == ">= 3.3"
    unless spec.metadata["rubygems_mfa_required"] == "true" && spec.metadata["allowed_push_host"] == "https://rubygems.org"
      found << "the metadata must require MFA and allow pushes to rubygems.org only"
    end
    found
  end

  def main(argv)
    path, tag = argv
    if path.nil? || argv.size > 2
      warn "Usage: ruby scripts/package_check.rb flashpi-X.Y.Z.gem [vX.Y.Z]"
      return 2
    end
    found = problems(path, tag)
    found.each { |problem| warn "#{path}: #{problem}" }
    return 1 unless found.empty?

    puts "#{path} holds the #{expected_files.size} files of the gem and nothing else"
    0
  end
end

exit(PackageCheck.main(ARGV)) if $PROGRAM_NAME == __FILE__
