require_relative "test_helper"

class TestMarkdownCodeBlock < KwardTestCase
  def test_finds_a_block_from_a_body_or_fence_selection
    source = "before\n```ruby\nputs 1\n```\nafter\n"

    body = Kward::MarkdownCodeBlock.for_selection(source, 2, 2)
    fence = Kward::MarkdownCodeBlock.for_selection(source, 1, 3)

    assert_equal :ruby, body.language.to_sym
    assert_equal "puts 1\n", body.code
    assert_equal :ruby, fence.language.to_sym
  end

  def test_selects_an_inner_fenced_block
    source = "````markdown\n```ruby\nputs 1\n```\n````\n"
    block = Kward::MarkdownCodeBlock.for_selection(source, 2, 2)

    assert_equal :ruby, block.language.to_sym
    assert_equal "puts 1\n", block.code
  end

  def test_inserts_formatted_output_after_the_block
    source = "```ruby\nputs 1\n```\n"
    block = Kward::MarkdownCodeBlock.for_selection(source, 1, 1)

    assert_equal "```ruby\nputs 1\n```\n\n<output>\n1\n</output>\n", block.with_output("1\n")
  end

  def test_replaces_and_reformats_inline_output
    source = "```ruby\nputs 1\n```\n<output>old</output>\n"
    block = Kward::MarkdownCodeBlock.for_selection(source, 1, 1)

    assert_equal "```ruby\nputs 1\n```\n<output>\nnew\n</output>\n", block.with_output("new\n")
  end

  def test_does_not_consume_output_after_the_next_code_fence
    source = "```ruby\nputs 1\n```\ntext\n```python\nprint(2)\n```\n<output>later</output>\n"
    block = Kward::MarkdownCodeBlock.for_selection(source, 1, 1)

    result = block.with_output("now\n")

    assert_includes result, "<output>\nnow\n</output>\ntext\n```python"
    assert_includes result, "```\n<output>later</output>\n"
  end
end
