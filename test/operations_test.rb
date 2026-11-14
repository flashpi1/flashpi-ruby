# frozen_string_literal: true

require_relative "test_helper"
require "rbs"

# Every operation of the API's OpenAPI document maps to exactly one method of the client, which
# sends its HTTP method, path, query and body, and whose RBS signature takes and returns the
# generated types of the contract.
class OperationsTest < Minitest::Test
  include Support

  ROOT = File.expand_path("..", __dir__)
  CONTRACT = JSON.parse(File.read(File.join(ROOT, "openapi", "openapi.json"), encoding: "UTF-8"))

  # Each operationId of the contract and the resource method that sends it.
  OPERATIONS = {
    "statusGet" => "status.get",
    "issuersCreate" => "issuers.create",
    "issuersList" => "issuers.list",
    "issuersGet" => "issuers.get",
    "issuersUpdate" => "issuers.update",
    "issuersDelete" => "issuers.delete",
    "establishmentsCreate" => "issuers.establishments.create",
    "establishmentsList" => "issuers.establishments.list",
    "establishmentsGet" => "issuers.establishments.get",
    "establishmentsUpdate" => "issuers.establishments.update",
    "establishmentsDelete" => "issuers.establishments.delete",
    "emissionPointsCreate" => "issuers.establishments.emission_points.create",
    "emissionPointsList" => "issuers.establishments.emission_points.list",
    "emissionPointsGet" => "issuers.establishments.emission_points.get",
    "emissionPointsDelete" => "issuers.establishments.emission_points.delete",
    "certificatesUpload" => "issuers.certificates.upload",
    "certificatesList" => "issuers.certificates.list",
    "certificatesGet" => "issuers.certificates.get",
    "issuerOnboardingsCreate" => "issuer_onboardings.create",
    "issuerOnboardingsGet" => "issuer_onboardings.get",
    "issuerOnboardingsComplete" => "issuer_onboardings.complete",
    "invoicesCreate" => "invoices.create",
    "creditNotesCreate" => "credit_notes.create",
    "debitNotesCreate" => "debit_notes.create",
    "purchaseSettlementsCreate" => "purchase_settlements.create",
    "waybillsCreate" => "waybills.create",
    "withholdingsCreate" => "withholdings.create",
    "documentsList" => "documents.list",
    "documentsGet" => "documents.get",
    "documentsGetXml" => "documents.xml",
    "documentsGetPdf" => "documents.pdf",
    "documentsSendEmail" => "documents.send_email",
    "webhookEndpointsCreate" => "webhook_endpoints.create",
    "webhookEndpointsList" => "webhook_endpoints.list",
    "webhookEndpointsGet" => "webhook_endpoints.get",
    "webhookEndpointsUpdate" => "webhook_endpoints.update",
    "webhookEndpointsDelete" => "webhook_endpoints.delete",
    "webhookEndpointsSecret" => "webhook_endpoints.get_secret",
    "webhookEndpointsRotateSecret" => "webhook_endpoints.rotate_secret",
    "webhookEndpointsVerify" => "webhook_endpoints.verify",
    "webhookEndpointsDeliveriesList" => "webhook_endpoints.deliveries.list",
    "webhookEndpointsDeliveriesGet" => "webhook_endpoints.deliveries.get",
    "webhookEndpointsDeliveriesReplay" => "webhook_endpoints.deliveries.replay",
    "eventsList" => "events.list",
    "eventsGet" => "events.get"
  }.freeze

  # Operations whose body the contract requires but whose method may leave out: `{}` is a valid
  # body (completing the renewal of an existing issuer), as in the Node SDK.
  EMPTY_BODY_ALLOWED = %w[issuerOnboardingsComplete].freeze

  # Operations whose body the SDK builds itself: send_email always sends `{}` ("no options yet").
  FIXED_BODY = { "documentsSendEmail" => {} }.freeze

  OPTIONS = %w[idempotency_key timeout max_retries language correlation_id extra_headers].freeze

  Operation = Struct.new(:id, :http_method, :path, :query, :body_type, :body_required, :body_schema, :answer_type,
                         :answer_schema, keyword_init: true)

  def self.schema_name(schema)
    reference = (schema || {})["$ref"]
    reference.is_a?(String) ? reference.split("/").last : nil
  end

  def self.contract_operations
    CONTRACT.fetch("paths").flat_map do |path, item|
      item.filter_map do |method, spec|
        next unless %w[get post patch put delete].include?(method)

        parameters = [*item.fetch("parameters", []), *spec.fetch("parameters", [])].map do |parameter|
          parameter["$ref"] ? CONTRACT.dig("components", "parameters", parameter["$ref"].split("/").last) : parameter
        end
        content = spec.dig("requestBody", "content") || {}
        success = spec.fetch("responses").keys.select { |status| status.start_with?("2") }.min
        answer = spec.dig("responses", success, "content") || {}
        Operation.new(
          id: spec.fetch("operationId"), http_method: method.to_sym, path:,
          query: parameters.select { |parameter| parameter["in"] == "query" }.map { |parameter| parameter["name"] },
          body_type: content.keys.first, body_required: spec.dig("requestBody", "required") == true,
          body_schema: schema_name(content.values.first&.fetch("schema", nil)),
          answer_type: answer.keys.first, answer_schema: schema_name(answer.values.first&.fetch("schema", nil))
        )
      end
    end
  end

  OPERATION_LIST = contract_operations.freeze

  def resource_of(client, route)
    *names, method = route.split(".")
    [names.reduce(client) { |object, name| object.public_send(name) }, method.to_sym]
  end

  def test_maps_every_operation_of_the_contract_and_nothing_else
    assert_equal 45, OPERATION_LIST.size
    assert_equal OPERATION_LIST.map(&:id).sort, OPERATIONS.keys.sort
  end

  def test_every_resource_has_only_the_methods_of_its_operations
    client = Flashpi::Client.new(api_key: TEST_KEY)
    expected = Hash.new { |hash, key| hash[key] = [] }
    OPERATIONS.each_value do |route|
      resource, method = resource_of(client, route)
      expected[resource.class] << method
    end
    nested = %i[establishments certificates emission_points deliveries]
    expected.each do |klass, methods|
      inherited = klass.superclass.public_instance_methods(false) - [:with_response]
      actual = klass.public_instance_methods(false) + inherited
      actual = actual.uniq - nested - Flashpi::Internal::Resource.public_instance_methods(false)
      assert_equal methods.sort, actual.sort, klass.name
      assert_equal methods.sort, (klass::WithResponse.public_instance_methods(false) & methods).sort
    end
  end

  def test_sends_the_method_path_query_and_body_of_every_operation
    OPERATION_LIST.each do |operation|
      api = fake_api(answer_of(operation))
      resource, method = resource_of(api.client, OPERATIONS.fetch(operation.id))
      ids = operation.path.scan(/\{(\w+)\}/).flatten.map { |name| "#{name}-1" }
      arguments = ids.dup
      body = { "probe" => operation.id }
      if operation.body_type == "application/json"
        arguments << body unless FIXED_BODY.key?(operation.id)
      elsif operation.body_type == "multipart/form-data"
        arguments << { file: "\x30\x82".b, password: "secret" }
      elsif !operation.query.empty?
        arguments << operation.query.to_h { |name| [name.to_sym, "#{name}-value"] }
      end
      result = resource.public_send(method, *arguments)
      attempt = api.sent.first
      expected_path = operation.path.gsub(/\{(\w+)\}/) { "#{Regexp.last_match(1)}-1" }
      path, query = attempt.target.split("?", 2)
      assert_equal [operation.http_method, expected_path], [attempt.http_method, path], operation.id
      if operation.query.empty?
        assert_nil query, operation.id
      else
        assert_equal operation.query.sort, URI.decode_www_form(query).map(&:first).sort, operation.id
      end
      check_body(operation, attempt, body)
      check_result(operation, result)
      assert_equal(operation.http_method == :post, attempt.headers.key?("idempotency-key"), operation.id)
    end
  end

  def test_leaves_out_an_optional_body_or_one_whose_empty_object_is_valid
    OPERATION_LIST.select { |operation| operation.body_type == "application/json" }.each do |operation|
      next if FIXED_BODY.key?(operation.id)

      resource, method = resource_of(Flashpi::Client.new(api_key: TEST_KEY), OPERATIONS.fetch(operation.id))
      optional = resource.method(method).parameters.any? { |kind, name| kind == :opt && name == :body }
      assert_equal(!operation.body_required || EMPTY_BODY_ALLOWED.include?(operation.id), optional, operation.id)
    end
  end

  def test_the_rbs_signature_of_every_operation_uses_the_contracts_types
    declarations = signatures
    OPERATION_LIST.each do |operation|
      resource, method = resource_of(Flashpi::Client.new(api_key: TEST_KEY), OPERATIONS.fetch(operation.id))
      klass = resource.class
      klass = klass.superclass if klass.superclass == Flashpi::Resources::DocumentIssuer
      type = declarations.fetch(klass.name.delete_prefix("Flashpi::Resources::")).fetch(method)
      assert_equal OPTIONS, type.type.optional_keywords.keys.map(&:to_s), operation.id
      assert_equal expected_answer(operation), type.type.return_type.to_s, operation.id
      check_filters(operation, type)
      body = (type.type.required_positionals + type.type.optional_positionals).find do |param|
        %i[body upload].include?(param.name)
      end
      next unless body && operation.body_schema

      expected = klass == Flashpi::Resources::DocumentIssuer ? "B" : "::Flashpi::Types::#{snake(operation.body_schema)}"
      assert_equal expected, body.type.to_s.delete_suffix("?").delete_prefix("(").delete_suffix(")"), operation.id
    end
  end

  def test_the_document_issuers_take_the_contracts_bodies
    text = File.read(File.join(ROOT, "sig", "flashpi", "resources.rbs"), encoding: "UTF-8")
    issuers = OPERATION_LIST.select do |operation|
      operation.answer_schema == "Document" && operation.http_method == :post
    end
    issuers.each do |operation|
      next if FIXED_BODY.key?(operation.id)

      klass = OPERATIONS.fetch(operation.id).split(".").first.split("_").map(&:capitalize).join
      assert_includes text, "class #{klass} < DocumentIssuer[Types::#{snake(operation.body_schema)}]", operation.id
    end
  end

  private

  def snake(name)
    name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
  end

  def expected_answer(operation)
    return "nil" if operation.answer_type.nil?
    return "::Flashpi::Types::document_xml" if operation.answer_type == "application/xml"
    return "::String" if operation.answer_type == "application/pdf"

    schema = operation.answer_schema
    if schema.end_with?("List")
      item = CONTRACT.dig("components", "schemas", schema, "properties", "data", "items")
      return "::Flashpi::Page[::Flashpi::Types::#{snake(self.class.schema_name(item))}]"
    end
    "::Flashpi::Types::#{snake(schema)}"
  end

  def signatures
    loader = RBS::EnvironmentLoader.new
    %w[net-http net-protocol openssl uri timeout].each { |library| loader.add(library:, version: nil) }
    loader.add(path: Pathname(File.join(ROOT, "sig")))
    environment = RBS::Environment.from_loader(loader).resolve_type_names
    @environment = environment
    builder = RBS::DefinitionBuilder.new(env: environment)
    resources = Flashpi::Resources.constants.filter_map do |name|
      klass = Flashpi::Resources.const_get(name)
      next unless klass.is_a?(Class) && klass < Flashpi::Internal::Resource

      definition = builder.build_instance(RBS::TypeName.parse("::Flashpi::Resources::#{name}"))
      [name.to_s, definition.methods.transform_values { |method| method.method_types.first }]
    end
    resources.to_h
  end

  # A list method takes, as `params`, an alias of the generated query of its operation.
  def check_filters(operation, type)
    params = type.type.optional_positionals.find { |param| param.name == :params }
    query = operation.query - %w[cursor]
    return assert_nil(params, operation.id) if operation.query.empty?

    name = params.type.to_s.delete_suffix("?").delete_prefix("(").delete_suffix(")")
    declaration = @environment.type_alias_decls.fetch(RBS::TypeName.parse(name)).decl
    assert_equal "::Flashpi::Types::#{snake(operation.id)}_query", declaration.type.to_s, operation.id
    refute_empty query, operation.id
  end

  def answer_of(operation)
    case operation.answer_type
    when nil then raw(204)
    when "application/xml" then raw(200, "<x/>", { "flashpi-xml-kind" => "signed" })
    when "application/pdf" then raw(200, "%PDF")
    else
      operation.answer_schema.end_with?("List") ? page([{ id: "item" }]) : json_response({ id: "thing" })
    end
  end

  def check_body(operation, attempt, body)
    case operation.body_type
    when "application/json"
      expected = FIXED_BODY.fetch(operation.id) { body }
      assert_equal JSON.generate(expected), attempt.content, operation.id
      assert_equal "application/json", attempt.headers["content-type"], operation.id
    when "multipart/form-data"
      assert_match %r{\Amultipart/form-data; boundary=}, attempt.headers["content-type"], operation.id
    else
      assert_nil attempt.content, operation.id
    end
  end

  def check_result(operation, result)
    case operation.answer_type
    when nil then assert_nil result, operation.id
    when "application/xml" then assert_equal({ xml: "<x/>", kind: "signed" }, result)
    when "application/pdf" then assert_equal "%PDF", result
    else
      if operation.answer_schema.end_with?("List")
        assert_instance_of Flashpi::Page, result, operation.id
      else
        assert_equal({ id: "thing" }, result, operation.id)
      end
    end
  end
end
