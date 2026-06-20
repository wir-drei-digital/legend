defmodule Legend.Core.Acp.Connection do
  @moduledoc """
  In-process Agent Client Protocol codec. Holds JSON-RPC framing state (line
  buffer, request-id correlation, per-turn reduction state) for one ACP session.
  Pure functions: the SessionServer owns the process and the runtime IO.
  """

  @protocol_version 1

  defstruct buf: "",
            next_id: 1,
            pending: %{},
            launch: nil,
            turn: 0,
            reduce: %{}

  @type t :: %__MODULE__{}

  @spec new(map()) :: {t(), [binary()]}
  def new(launch) do
    state = %__MODULE__{launch: launch}

    {state, frame} =
      request(
        state,
        "initialize",
        %{
          "protocolVersion" => @protocol_version,
          # Phase 1: no client-side fs/terminal capabilities.
          "clientCapabilities" => %{}
        },
        :initialize
      )

    {state, [frame]}
  end

  @spec handle_bytes(t(), binary()) :: {t(), [map()], [binary()], [tuple()]}
  def handle_bytes(state, bytes) do
    {lines, buf} = split_lines(state.buf <> bytes)
    state = %{state | buf: buf}

    Enum.reduce(lines, {state, [], [], []}, fn line, {st, items, replies, effects} ->
      case Jason.decode(line) do
        {:ok, msg} ->
          {st, i, r, e} = dispatch(st, msg)
          {st, items ++ i, replies ++ r, effects ++ e}

        {:error, _} ->
          # Malformed frame: skip, never crash the session.
          {st, items, replies, effects}
      end
    end)
  end

  # --- framing helpers ---

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete |> Enum.reject(&(&1 == "")), rest}
  end

  defp request(state, method, params, tag) do
    id = state.next_id

    frame =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) <>
        "\n"

    {%{state | next_id: id + 1, pending: Map.put(state.pending, id, tag)}, frame}
  end

  # notify/2 (agent->client notifications) and response/2 (replies to agent->client
  # requests) are part of this framing block per the design, but have no callers
  # until Tasks 6 & 7 wire them in. They are added in those tasks alongside their
  # first use because this project compiles with --warnings-as-errors and Elixir
  # 1.20 no longer honors @compile {:nowarn_unused_function, ...} for unused
  # private functions, so an unused helper here would break the build.

  # --- dispatch: responses to our requests ---

  defp dispatch(state, %{"id" => id, "result" => result}) when is_map_key(state.pending, id) do
    {tag, pending} = Map.pop(state.pending, id)
    handle_response(%{state | pending: pending}, tag, result)
  end

  defp dispatch(state, %{"id" => id, "error" => err}) when is_map_key(state.pending, id) do
    {_tag, pending} = Map.pop(state.pending, id)
    # Surface as a soft error item; do not crash.
    item = %{"id" => "error-#{id}", "type" => "error", "text" => inspect(err)}
    {%{state | pending: pending}, [item], [], []}
  end

  # session/update notifications + agent->client requests handled in Tasks 6 & 7.
  defp dispatch(state, msg), do: dispatch_incoming(state, msg)

  defp handle_response(state, :initialize, result) do
    caps = result["agentCapabilities"] || %{}
    load? = caps["loadSession"] == true
    launch = state.launch
    mcp = launch[:mcp_servers] || []

    {state, frame} =
      case launch[:mode] do
        :load ->
          request(
            state,
            "session/load",
            %{
              "sessionId" => launch[:conversation_id],
              "cwd" => launch[:cwd],
              "mcpServers" => mcp
            },
            :session_load
          )

        _ ->
          request(
            state,
            "session/new",
            %{"cwd" => launch[:cwd], "mcpServers" => mcp},
            :session_new
          )
      end

    {state, [], [frame], [{:load_capable, load?}]}
  end

  defp handle_response(state, :session_new, result) do
    cid = result["sessionId"]
    {state, replies, effects} = maybe_initial_prompt(state)
    {state, [], replies, [{:conversation_id, cid} | effects]}
  end

  defp handle_response(state, :session_load, _result) do
    # History replays as session/update notifications (handled in Task 6).
    {state, [], [], []}
  end

  defp handle_response(state, :prompt, result) do
    {state, [], [], [{:turn, result["stopReason"]}]}
  end

  defp handle_response(state, _tag, _result), do: {state, [], [], []}

  # Send the instructions as the first prompt on a fresh session only.
  defp maybe_initial_prompt(%{launch: %{mode: :new, instructions: text}} = state)
       when is_binary(text) and text != "" do
    {state, replies, _items} = do_prompt(state, text)
    {state, replies, []}
  end

  defp maybe_initial_prompt(state), do: {state, [], []}

  # do_prompt/dispatch_incoming defined in Tasks 6 & 7; stub for now:
  defp do_prompt(state, _text), do: {state, [], []}
  defp dispatch_incoming(state, _msg), do: {state, [], [], []}
end
