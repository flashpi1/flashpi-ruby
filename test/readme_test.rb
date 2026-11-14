# frozen_string_literal: true

require_relative "test_helper"
require_relative "../scripts/readme"

# The README examples are checked by Steep and RuboCop from test/examples/readme; these tests keep
# those files in step with the READMEs and compile each one on the running Ruby.
class ReadmeTest < Minitest::Test
  def test_the_examples_match_the_readmes
    assert_equal Readme.examples, Readme.current, "Run: ruby scripts/readme.rb generate"
  end

  def test_every_example_compiles
    Readme.examples.each do |name, code|
      RubyVM::InstructionSequence.compile(code, name)
    end
  end

  def test_finds_the_blocks_with_the_heading_above_them
    text = "# Title\n\n## Errors\n\n```ruby\nputs 1\n```\n\n```bash\nls\n```\n\n```rb\nputs 2\n```\n"
    blocks = Readme.ruby_blocks("README.md", text)
    found = blocks.map { |block| [block.line, block.section, block.code] }
    assert_equal [[5, "Errors", "puts 1\n"], [13, "Errors", "puts 2\n"]], found
    assert_raises(Readme::ExampleError) { Readme.ruby_blocks("README.md", "```ruby\nputs 1\n") }
  end

  def test_links_to_each_other_and_to_the_license_with_absolute_urls
    %w[README.md README.en.md].each do |readme|
      text = File.read(File.join(Readme::ROOT, readme), encoding: "UTF-8")
      links = text.scan(/\]\(([^)]+)\)/).flatten
      relative = links.reject { |link| link.start_with?("https://") }
      assert_empty relative, readme
      assert_includes text, "https://github.com/flashpi1/flashpi-ruby/blob/main/LICENSE"
    end
  end

  def test_both_readmes_show_the_same_code
    blocks = Readme::READMES.values.map do |readme|
      Readme.ruby_blocks(readme, File.read(File.join(Readme::ROOT, readme), encoding: "UTF-8"))
    end
    assert_equal blocks[0].size, blocks[1].size
    blocks[0].zip(blocks[1]).each do |spanish, english|
      code = ->(block) { block.code.gsub(/"(?:[^"\\]|\\.)*"/, '""').gsub(/#.*$/, "").gsub(/\s+/, " ") }
      assert_equal code.call(spanish), code.call(english), "#{spanish.line} / #{english.line}"
    end
  end
end
