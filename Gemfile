# frozen_string_literal: true

source "https://rubygems.org"

# The tools of this repository. The gem itself has no runtime dependencies, so the Gemfile does not
# load its gemspec: the lockfile holds no version of flashpi for a release to update, and the
# tests load lib/ themselves.

# What the tests need. CI runs them on each Ruby without the lint group, so they load that Ruby's
# own json, uri and securerandom, as the gem's users do.
group :development do
  gem "minitest", "~> 6.1"
  gem "rake", "~> 13.4"
  gem "rbs", "~> 4.2"
end

# RuboCop and Steep, which bring newer json and uri gems with them.
group :lint do
  gem "rubocop", "~> 1.93"
  gem "rubocop-minitest", "~> 0.41"
  gem "rubocop-rake", "~> 0.7"
  gem "steep", "~> 2.1"
end
