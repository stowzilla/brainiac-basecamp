# frozen_string_literal: true

require_relative "test_helper"

class TestCommentResponder < Minitest::Test
  RESPONDER = Brainiac::Plugins::Basecamp::CommentResponder

  def test_detects_native_basecamp_mention
    accounts = { "1" => { "default_agent" => "Kaylee" } }
    Brainiac::Plugins::Basecamp::Config.stub(:current, { "bot_accounts" => accounts }) do
      content = '<bc-attachment sgid="abc" content-type="application/vnd.basecamp.mention">@Kaylee</bc-attachment>'

      assert_equal "Kaylee", RESPONDER.send(:detect_mentioned_agent, content)
    end
  end

  def test_strips_markup_and_preserves_mention_text
    content = '<p>Hello <bc-attachment content-type="application/vnd.basecamp.mention">@Kaylee</bc-attachment>!</p>'

    assert_equal "Hello @Kaylee!", RESPONDER.send(:strip_html_preserve_mentions, content)
  end

  def test_discards_unclosed_markup
    assert_equal "Hello", RESPONDER.send(:strip_html_preserve_mentions, "Hello<script")
  end

  def test_handles_repeated_unclosed_attachments
    content = '<bc-attachment content-type="application/vnd.basecamp.mention">' * 1_000

    assert_nil RESPONDER.send(:detect_mentioned_agent, content)
    assert_equal "", RESPONDER.send(:strip_html_preserve_mentions, content)
  end
end
