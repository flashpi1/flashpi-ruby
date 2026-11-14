# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.test_files = FileList["test/**/*_test.rb"].exclude("test/live/**/*")
  task.warning = true
end

Rake::TestTask.new("test:live") do |task|
  task.libs << "test"
  task.test_files = FileList["test/live/**/*_test.rb"]
end

desc "Check the types with Steep"
task :steep do
  sh "bundle exec steep check"
end

desc "Lint with RuboCop"
task :rubocop do
  sh "bundle exec rubocop"
end

namespace :openapi do
  desc "Fail when sig/flashpi/types.rbs does not match openapi/openapi.json"
  task(:check) { ruby "scripts/openapi.rb check" }

  desc "Regenerate sig/flashpi/types.rbs from openapi/openapi.json"
  task(:generate) { ruby "scripts/openapi.rb generate" }

  desc "Download the public OpenAPI document, then regenerate the types"
  task(:sync) { ruby "scripts/openapi.rb sync" }
end

task default: %i[openapi:check rubocop steep test]
