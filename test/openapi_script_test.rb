# frozen_string_literal: true

require_relative "test_helper"
require_relative "../scripts/openapi"
require "rbs"

# scripts/openapi.rb: the RBS it writes, and the constructs it refuses rather than translate
# wrongly.
class OpenAPIScriptTest < Minitest::Test
  def document(schemas: {}, paths: {}, parameters: {})
    { "openapi" => "3.1.0", "paths" => paths, "components" => { "schemas" => schemas, "parameters" => parameters } }
  end

  def generate(**parts)
    OpenAPI::Generator.new(document(**parts)).generate
  end

  def list_operation(parameters, item = {})
    { "/v1/things" => item.merge("get" => { "operationId" => "thingsList", "parameters" => parameters }) }
  end

  def test_the_committed_types_match_the_contract
    contract = File.read(OpenAPI::CONTRACT_PATH, encoding: "UTF-8")
    assert_equal OpenAPI.generate(contract), File.read(OpenAPI::TYPES_PATH, encoding: "UTF-8")
    assert_equal 0, OpenAPI.main(["check"])
  end

  def test_writes_records_enums_unions_and_nullable_members
    rbs = generate(schemas: {
                     "Thing" => {
                       "type" => "object", "required" => %w[id status], "description" => "A thing.",
                       "properties" => {
                         "id" => { "type" => "string", "format" => "uuid" },
                         "status" => { "type" => "string", "enum" => %w[on off] },
                         "count" => { "type" => %w[number null] },
                         "tags" => { "type" => "array", "items" => { "$ref" => "#/components/schemas/Tag" } },
                         "extra" => { "type" => "object", "additionalProperties" => { "type" => "string" } }
                       }
                     },
                     "Tag" => { "type" => "string", "enum" => ["a", "b", nil] }
                   })
    assert_includes rbs, "    # A thing.\n    type thing = {\n"
    assert_includes rbs, "      status: thing_status,\n"
    assert_includes rbs, "      ?count: (Integer | Float)?,\n"
    assert_includes rbs, "      ?tags: Array[tag],\n"
    assert_includes rbs, "      ?extra: Hash[Symbol, String]\n"
    assert_includes rbs, "    type thing_status = \"on\" | \"off\"\n"
    assert_includes rbs, "    type tag = (\"a\" | \"b\")?\n"
    assert_includes rbs, "      # Format: uuid.\n      id: String,\n"
    RBS::Parser.parse_signature(rbs) if defined?(RBS)
  end

  def test_merges_the_parameters_of_the_path_item_with_the_operations
    paths = list_operation(
      [{ "name" => "limit", "in" => "query", "schema" => { "type" => "integer" } },
       { "name" => "region", "in" => "query", "required" => true, "schema" => { "type" => "string" } }],
      { "parameters" => [{ "name" => "region", "in" => "query", "schema" => { "type" => "integer" } },
                         { "name" => "shared", "in" => "query", "schema" => { "type" => "boolean" } }] }
    )
    rbs = generate(paths:)
    assert_includes rbs, "    type things_list_query = {\n"
    assert_includes rbs, "      ?shared: bool,\n"
    assert_includes rbs, "      ?limit: Integer,\n"
    assert_includes rbs, "      region: String\n"
  end

  def test_refuses_what_it_cannot_translate_faithfully
    refused = [
      document.merge("openapi" => "3.0.3"),
      document(schemas: { "A" => { "type" => "string", "pattern" => "x", "xml" => {} } }),
      document(schemas: { "A" => { "$ref" => "#/components/schemas/B", "type" => "string" },
                          "B" => { "type" => "string" } }),
      document(schemas: { "A" => { "allOf" => [{ "type" => "string" }, { "type" => "integer" }] } }),
      document(schemas: { "A" => { "type" => "object", "properties" => { "bad-key" => { "type" => "string" } } } }),
      document(schemas: { "A" => { "type" => "object", "required" => ["x"], "properties" => {} } }),
      document(schemas: { "A" => { "type" => %w[string integer] } }),
      document(schemas: { "A" => { "$ref" => "#/components/schemas/Missing" } }),
      document(paths: list_operation([{ "name" => "ids", "in" => "query", "style" => "form", "explode" => false,
                                        "schema" => { "type" => "array", "items" => { "type" => "string" } } }])),
      document(paths: list_operation([{ "name" => "q", "in" => "query",
                                        "content" => { "application/json" => { "schema" => {} } } }])),
      document(paths: list_operation([], { "head" => { "operationId" => "thingsHead" } })),
      document(paths: list_operation([], { "$ref" => "#/paths/other" }))
    ]
    refused.each do |contract|
      assert_raises(OpenAPI::GenerationError, contract.inspect) { OpenAPI::Generator.new(contract).generate }
    end
  end

  def test_downloads_over_https_only
    assert_raises(RuntimeError) { OpenAPI.fetch(URI.parse("http://flashpi.com.ec/docs/openapi.json"), 5) }
    assert_raises(RuntimeError) { OpenAPI.fetch(URI.parse("ftp://flashpi.com.ec/openapi.json"), 5) }
  end

  def test_names_aliases_in_snake_case
    assert_equal "create_webhook_endpoint", OpenAPI.snake("CreateWebhookEndpoint")
    assert_equal "api_key", OpenAPI.snake("APIKey")
    assert_equal "document_xml_kind", OpenAPI.snake("DocumentXmlKind")
  end

  def test_rejects_an_unknown_mode
    assert_equal 2, OpenAPI.main(["upload"])
  end
end
