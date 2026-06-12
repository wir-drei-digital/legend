defmodule Legend.Core.Harness.Terminal do
  @moduledoc """
  Contract for `:terminal`-kind harnesses: build the CLI invocation.

  ## Library primer contract

  When opts contain `:library`, the harness SHOULD deliver `library.primer`
  through its CLI's native context mechanism (e.g. a system-prompt flag) and
  MUST NOT inject it as fake user input (no PTY injection). A harness whose
  CLI has no such mechanism delivers nothing — the platform-injected
  `LEGEND_LIBRARY` env var still applies. Plugin harnesses implement their own
  delivery against this contract.

  ## Messaging contract

  When opts contain `:mcp`, the harness SHOULD register Legend's MCP server
  (`mcp.url`, bearer `mcp.token`) through its CLI's native MCP mechanism; the
  platform-injected `LEGEND_MCP_URL`/`LEGEND_SESSION_TOKEN` env vars are the
  universal fallback. When opts contain `:messaging`, `messaging.primer` joins
  the library primer through the same context mechanism, and a non-nil
  `messaging.instructions` is delivered as the CLI's initial prompt. None of
  these are ever PTY-injected; the only runtime injection is the one-line
  nudge, whose format a harness may override via the optional `nudge_line/2`.

  ## Resume contract

  When opts contain `:session_id`, a resumable harness SHOULD pin the agent's
  conversation id to it at fresh launch and reopen that conversation when
  `mode: :resume` (omitting `messaging.instructions` — the conversation already
  contains them). Harnesses without a resume mechanism ignore `:mode`; resume
  degrades to a fresh process. Declare support via `Definition.resumable`.
  """

  @type library :: %{path: String.t(), primer: String.t()}
  @type mcp :: %{url: String.t(), token: String.t()}
  @type messaging :: %{primer: String.t(), instructions: String.t() | nil}
  @type opts :: %{
          optional(:env) => %{String.t() => String.t()},
          optional(:library) => library(),
          optional(:mcp) => mcp(),
          optional(:messaging) => messaging(),
          optional(:mode) => :fresh | :resume,
          optional(:session_id) => String.t()
        }

  @callback build_command(opts()) :: Legend.Core.Runtime.CommandSpec.t()
  @callback nudge_line(count :: pos_integer(), from :: String.t()) :: String.t()
  @optional_callbacks nudge_line: 2

  @doc "Resolves the nudge line via the harness override or the default."
  def nudge_line(harness, count, from) do
    from = sanitize_label(from)

    if function_exported?(harness, :nudge_line, 2) do
      harness.nudge_line(count, from)
    else
      default_nudge_line(count, from)
    end
  end

  # The label flows from an agent-controllable session name into PTY stdin —
  # strip control chars (CR/LF/ESC/etc.) so it can't inject keystrokes or ANSI
  # sequences into the recipient's terminal, and bound its length.
  defp sanitize_label(from) when is_binary(from) do
    from
    |> String.replace(~r/[[:cntrl:]]/u, "")
    |> String.slice(0, 80)
  end

  defp sanitize_label(_), do: "unknown"

  @doc false
  def default_nudge_line(count, from) do
    "[legend] #{count} unread message(s) from #{from} — call read_messages to view"
  end

  @doc "Joins the library and messaging primers for single-flag delivery."
  def primers(opts) do
    [get_in(opts, [:library, :primer]), get_in(opts, [:messaging, :primer])]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  @doc "The initial-prompt text, or nil."
  def instructions(opts) do
    case get_in(opts, [:messaging, :instructions]) do
      text when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end
end
