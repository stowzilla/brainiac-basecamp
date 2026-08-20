# frozen_string_literal: true

require_relative "test_helper"

class TestBasecampPlugin < Minitest::Test
  def test_register_method_exists
    assert_respond_to Brainiac::Plugins::Basecamp, :register
  end

  def test_version_defined
    assert_match(/\A\d+\.\d+\.\d+\z/, Brainiac::Plugins::Basecamp::VERSION)
  end

  def test_cli_method_exists
    assert_respond_to Brainiac::Plugins::Basecamp, :cli
  end

  def test_configured_returns_boolean
    result = Brainiac::Plugins::Basecamp.configured?
    assert_includes [true, false], result
  end

  def test_help_text_defined
    text = Brainiac::Plugins::Basecamp.help_text
    assert_kind_of String, text
    assert_includes text, "brainiac basecamp"
  end
end
