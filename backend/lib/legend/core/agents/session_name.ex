defmodule Legend.Core.Agents.SessionName do
  @moduledoc """
  Derives a human-readable session name from prompt text — the launch
  `instructions` (Session.:start) or the first ACP prompt (SessionServer).

  Pure and side-effect free: text in, a clean title of at most ~50 graphemes
  out (plus a trailing ellipsis when truncated), or `nil` when nothing usable
  remains. Control characters are stripped so the result is safe to render in
  the PTY nudge label.
  """

  @target 50

  @doc "Derive a session name from prompt text; `nil` for blank/unusable input."
  @spec derive(String.t() | nil) :: String.t() | nil
  def derive(text) when is_binary(text) do
    text
    |> first_prose_line()
    |> strip_markdown()
    |> strip_control()
    |> collapse_whitespace()
    |> ellipsize(@target)
    |> nilify_blank()
  end

  def derive(_), do: nil

  # First non-blank line that is neither a code-fence marker nor inside a fence.
  defp first_prose_line(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> drop_until_prose(false)
  end

  defp drop_until_prose([], _in_fence), do: ""

  defp drop_until_prose([line | rest], in_fence) do
    cond do
      fence?(line) -> drop_until_prose(rest, not in_fence)
      in_fence -> drop_until_prose(rest, in_fence)
      line == "" -> drop_until_prose(rest, in_fence)
      true -> line
    end
  end

  defp fence?(line), do: String.starts_with?(line, "```") or String.starts_with?(line, "~~~")

  defp strip_markdown(line) do
    line
    # leading heading / blockquote / list markers (possibly repeated, e.g. "> - ")
    |> String.replace(~r/^\s*(?:[#>]+\s*|[-*+]\s+|\d+[.)]\s+)+/u, "")
    # markdown links/images: [text](url) / ![alt](url) -> text/alt
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/u, "\\1")
    # inline code backticks
    |> String.replace("`", "")
    # bold/italic/strikethrough emphasis markers
    |> String.replace(~r/(\*\*|\*|__|_|~~)/u, "")
    |> String.trim()
  end

  # Drop non-whitespace control characters (e.g. BEL, NUL) so the result is safe
  # for the PTY nudge label. Whitespace controls (tab, etc.) are left for
  # collapse_whitespace/1 so word boundaries survive as a single space.
  defp strip_control(s), do: String.replace(s, ~r/(?![[:space:]])[[:cntrl:]]/u, "")

  defp collapse_whitespace(s), do: s |> String.replace(~r/\s+/u, " ") |> String.trim()

  # Truncate to `target` graphemes, backing off to the last word boundary; append
  # an ellipsis when the text was cut. A single over-long word is hard-cut.
  defp ellipsize(s, target) do
    if String.length(s) <= target do
      s
    else
      head = String.slice(s, 0, target)

      cut =
        case String.split(head, " ") do
          parts when length(parts) > 1 -> parts |> Enum.drop(-1) |> Enum.join(" ")
          _ -> head
        end

      String.trim_trailing(cut) <> "…"
    end
  end

  defp nilify_blank(""), do: nil
  defp nilify_blank("…"), do: nil
  defp nilify_blank(s), do: s
end
