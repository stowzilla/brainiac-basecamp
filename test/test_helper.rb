# frozen_string_literal: true

require "minitest/autorun"
# Older Minitest releases load Object#stub from this separate file; in current
# Minitest it is included by minitest/autorun and the file no longer exists.
begin
  require "minitest/mock"
rescue LoadError
  # Minitest 6 removed the mock extension. Keep the test suite runnable with
  # the system Ruby as well as the project's Minitest 5 dependency.
  class Object
    def stub(method_name, value, &)
      singleton = class << self; self; end
      original = "__test_original_#{method_name}"
      singleton.alias_method(original, method_name)
      singleton.define_method(method_name) do |*args, **kwargs, &method_block|
        value.respond_to?(:call) ? value.call(*args, **kwargs, &method_block) : value
      end
      yield
    ensure
      singleton.define_method(method_name, singleton.instance_method(original))
      singleton.remove_method(original)
    end
  end
end
require "json"
require "fileutils"
require "tmpdir"

TEST_BRAINIAC_DIR = Dir.mktmpdir("brainiac-basecamp-test")
ENV["BRAINIAC_DIR"] = TEST_BRAINIAC_DIR

unless defined?(LOG)
  LOG = Class.new do
    def info(_msg) = nil
    def warn(_msg) = nil
    def error(_msg) = nil
    def debug(_msg) = nil
    def debug? = false
  end.new
end

module Brainiac
  @hooks = Hash.new { |h, k| h[k] = [] }
  @channel_prompts = {}
  @channel_pre_post_checks = {}

  class << self
    def on(event, &block) = @hooks[event] << block

    def emit(event, **ctx)
      @hooks[event].filter_map do |h|
        h.call(ctx)
      rescue StandardError
        nil
      end
    end

    def register_channel_prompt(channel, prompt, pre_post_check: nil)
      @channel_prompts[channel] = prompt
      @channel_pre_post_checks[channel] = pre_post_check if pre_post_check
    end

    attr_reader :hooks, :channel_prompts, :channel_pre_post_checks

    def reset_hooks!
      @hooks = Hash.new { |h, k| h[k] = [] }
      @channel_prompts = {}
      @channel_pre_post_checks = {}
    end
  end

  module Plugins; end
end

AGENT_REGISTRY = {}.freeze
PROJECTS = {}.freeze

require_relative "../lib/brainiac_basecamp"

Minitest.after_run { FileUtils.rm_rf(TEST_BRAINIAC_DIR) }
