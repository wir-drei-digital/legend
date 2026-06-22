defmodule Legend.Core.Agents.SessionNameTest do
  use ExUnit.Case, async: true

  alias Legend.Core.Agents.SessionName

  describe "derive/1 — blank input" do
    test "nil is nil", do: assert(SessionName.derive(nil) == nil)
    test "empty string is nil", do: assert(SessionName.derive("") == nil)
    test "whitespace only is nil", do: assert(SessionName.derive("   \n\t  ") == nil)
    test "punctuation/markers only is nil", do: assert(SessionName.derive("###") == nil)
    test "non-binary is nil", do: assert(SessionName.derive(%{}) == nil)
  end

  describe "derive/1 — plain text" do
    test "short prose is kept verbatim" do
      assert SessionName.derive("Fix the login bug") == "Fix the login bug"
    end

    test "only the first line is used" do
      assert SessionName.derive("Fix the login bug\nand also the logout one") ==
               "Fix the login bug"
    end

    test "internal whitespace runs collapse" do
      assert SessionName.derive("Fix    the\tlogin   bug") == "Fix the login bug"
    end
  end

  describe "derive/1 — markdown" do
    test "strips a heading marker" do
      assert SessionName.derive("# Refactor the auth module") == "Refactor the auth module"
    end

    test "strips a list marker" do
      assert SessionName.derive("- do the thing") == "do the thing"
    end

    test "strips a numbered marker" do
      assert SessionName.derive("1. first step") == "first step"
    end

    test "strips blockquote marker" do
      assert SessionName.derive("> quoted task") == "quoted task"
    end

    test "unwraps a markdown link to its text" do
      assert SessionName.derive("See [the issue](https://example.com/123)") ==
               "See the issue"
    end

    test "strips inline code and emphasis" do
      assert SessionName.derive("Update `config` and **rebuild**") == "Update config and rebuild"
    end
  end

  describe "derive/1 — code fences" do
    test "skips a leading fenced block to the first prose line" do
      assert SessionName.derive("```elixir\ndef foo, do: :ok\n```\nWire up the endpoint") ==
               "Wire up the endpoint"
    end

    test "an input that is only a fenced block is nil" do
      assert SessionName.derive("```\nsome code\n```") == nil
    end
  end

  describe "derive/1 — control chars" do
    test "strips embedded control characters" do
      assert SessionName.derive("Fix the \a bug") == "Fix the bug"
    end
  end

  describe "derive/1 — length" do
    test "long text is ellipsized on a word boundary within ~51 graphemes" do
      result = SessionName.derive(String.duplicate("word ", 40))
      assert String.length(result) <= 51
      assert String.ends_with?(result, "…")
      refute String.ends_with?(result, " …")
    end

    test "a single over-long word is hard-cut with an ellipsis" do
      result = SessionName.derive(String.duplicate("a", 80))
      assert String.length(result) == 51
      assert String.ends_with?(result, "…")
    end
  end
end
