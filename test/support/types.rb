# frozen_string_literal: true

require "rbs"
require "rbs/test"

module Support
  # Whether `value` is of the RBS `type`, as the gem's signatures in sig/ declare it.
  def typed?(value, type)
    @builder ||= begin
      loader = RBS::EnvironmentLoader.new
      %w[net-http net-protocol openssl uri timeout].each { |library| loader.add(library:, version: nil) }
      loader.add(path: Pathname(File.expand_path("../../sig", __dir__)))
      RBS::DefinitionBuilder.new(env: RBS::Environment.from_loader(loader).resolve_type_names)
    end
    RBS::Test::TypeCheck.new(self_class: Object, builder: @builder, sample_size: 100, unchecked_classes: [])
                        .value(value, RBS::Parser.parse_type(type))
  end
end
