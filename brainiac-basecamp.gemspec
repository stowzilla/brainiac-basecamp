# frozen_string_literal: true

require_relative "lib/brainiac/plugins/basecamp/version"

Gem::Specification.new do |s|
  s.name        = "brainiac-basecamp"
  s.version     = Brainiac::Plugins::Basecamp::VERSION
  s.summary     = "Basecamp epic orchestration plugin for Brainiac"
  s.description = "Manages epics in Basecamp with autonomous agent orchestration. " \
                  "Tracks dependencies between Fizzy cards, dispatches agents in sequence, " \
                  "and syncs completion status bidirectionally."
  s.authors     = ["Andy Davis"]
  s.homepage    = "https://github.com/stowzilla/brainiac-basecamp"
  s.license     = "MIT"
  s.required_ruby_version = ">= 3.4"

  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  s.require_paths = ["lib"]

  s.add_dependency "brainiac", ">= 0.0.23"

  s.add_development_dependency "minitest", "~> 5.25"
  s.add_development_dependency "rake", "~> 13.0"
  s.add_development_dependency "rubocop", "~> 1.75"
  s.add_development_dependency "rubocop-performance", "~> 1.25"

  s.metadata["rubygems_mfa_required"] = "true"
end
