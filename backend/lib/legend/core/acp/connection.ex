defmodule Legend.Core.Acp.Connection do
  @moduledoc """
  In-process Agent Client Protocol codec. Holds JSON-RPC framing state (line
  buffer, request-id correlation, per-turn reduction state) for one ACP session.
  Pure functions: the SessionServer owns the process and the runtime IO.
  """

  @protocol_version 1

  # Cap each tool entry's accumulated "output" so a long-running / chatty tool
  # cannot grow state.reduce without bound. We keep the TAIL (most recent output
  # is the most relevant) plus a leading truncation marker. The AcpTimeline holds
  # the canonical copy by id; this only bounds the per-update reducer working set.
  @max_tool_output 65_536
  @tool_output_truncation_marker "…[output truncated]…\n"

  defstruct buf: "",
            next_id: 1,
            pending: %{},
            launch: nil,
            turn: 0,
            # Whether the CURRENT turn has seen any agent-side output yet. Drives
            # session/load replay turn-boundary detection: a user chunk that
            # follows agent output begins a new turn (see reduce_update/3).
            turn_seen_response: false,
            reduce: %{},
            session_id: nil,
            perms: %{}

  @type t :: %__MODULE__{}

  @doc "Per-tool accumulated-output byte cap. Exposed for tests/inspection."
  @spec max_tool_output() :: pos_integer()
  def max_tool_output, do: @max_tool_output

  @doc "Test/inspection helper: whether a key is present in the reducer map."
  @spec reduce_has_key?(t(), String.t()) :: boolean()
  def reduce_has_key?(state, key), do: Map.has_key?(state.reduce, key)

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

  # --- outbound client->agent operations ---

  @spec prompt(t(), String.t() | [map()]) :: {t(), [binary()]}
  def prompt(state, content) do
    blocks = to_blocks(content)
    turn = state.turn + 1
    # Drop the prior turn's accumulated conversational entries (bounded growth):
    # msg-/thought-/user- of the turn we're leaving. Tool entries are pruned on
    # completion in reduce_update/3. A live prompt starts a fresh turn, so reset
    # the replay turn-boundary flag too.
    reduce =
      Map.drop(state.reduce, [
        "msg-#{state.turn}",
        "thought-#{state.turn}",
        "user-#{state.turn}"
      ])

    state = %{state | turn: turn, reduce: reduce, turn_seen_response: false}
    frame = prompt_frame(state, blocks)

    {%{
       state
       | next_id: state.next_id + 1,
         pending: Map.put(state.pending, state.next_id, :prompt)
     }, [frame]}
  end

  @doc """
  True when a `session/prompt` request is still awaiting its response — i.e. a
  turn is in flight. Single source of truth for "a turn is running" (covers the
  launch initial-instructions prompt as well, since it's tagged `:prompt`).
  """
  @spec turn_in_flight?(t()) :: boolean()
  def turn_in_flight?(state) do
    Enum.any?(state.pending, fn {_id, tag} -> tag == :prompt end)
  end

  defp prompt_frame(state, blocks) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => state.next_id,
      "method" => "session/prompt",
      "params" => %{"sessionId" => state.session_id, "prompt" => blocks}
    }) <> "\n"
  end

  defp to_blocks(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  defp to_blocks(blocks) when is_list(blocks), do: blocks
  # Defense in depth: a non-string/non-list content must never crash the session.
  defp to_blocks(_), do: []

  @spec cancel(t()) :: {t(), [binary()]}
  def cancel(state),
    do: {state, [notify("session/cancel", %{"sessionId" => state.session_id})]}

  @spec set_mode(t(), String.t()) :: {t(), [binary()]}
  def set_mode(state, mode_id) do
    {state, frame} =
      request(
        state,
        "session/set_mode",
        %{"sessionId" => state.session_id, "modeId" => mode_id},
        :set_mode
      )

    {state, [frame]}
  end

  @spec answer_permission(t(), String.t(), String.t()) :: {t(), [binary()]}
  def answer_permission(state, request_id, option_id) do
    case Map.pop(state.perms, request_id) do
      {nil, _} ->
        {state, []}

      {jsonrpc_id, perms} ->
        reply =
          response(jsonrpc_id, %{
            "outcome" => %{"outcome" => "selected", "optionId" => option_id}
          })

        {%{state | perms: perms}, [reply]}
    end
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

  defp notify(method, params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n"
  end

  defp response(id, result) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n"
  end

  # --- dispatch: responses to our requests ---

  defp dispatch(state, %{"id" => id, "result" => result}) when is_map_key(state.pending, id) do
    {tag, pending} = Map.pop(state.pending, id)
    handle_response(%{state | pending: pending}, tag, result)
  end

  defp dispatch(state, %{"id" => id, "error" => err}) when is_map_key(state.pending, id) do
    {tag, pending} = Map.pop(state.pending, id)
    # Surface as a soft error item; do not crash.
    item = %{"id" => "error-#{id}", "type" => "error", "text" => inspect(err)}
    # A failed prompt must still complete the turn lifecycle — otherwise the
    # server stays "busy" forever and the prompt queue never drains. Other tags
    # (initialize/session_new/session_load/set_mode) keep just the error item.
    effects = if tag == :prompt, do: [{:turn, "error"}], else: []
    {%{state | pending: pending}, [item], [], effects}
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
    state = %{state | session_id: cid}
    {state, replies, effects} = maybe_initial_prompt(state)
    {state, [], replies, [{:conversation_id, cid} | effects]}
  end

  defp handle_response(state, :session_load, _result) do
    # session/load has no sessionId in the result — keep the launch conversation_id.
    # History replays as session/update notifications (handled in Task 6).
    {%{state | session_id: state.launch[:conversation_id]}, [], [], []}
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

  defp do_prompt(state, text) do
    {state, frames} = prompt(state, text)
    {state, frames, []}
  end

  # --- inbound agent->client requests ---

  defp dispatch_incoming(state, %{
         "id" => id,
         "method" => "session/request_permission",
         "params" => p
       }) do
    item = %{
      "id" => "perm-#{id}",
      "type" => "permission",
      "title" => get_in(p, ["toolCall", "title"]) || "Permission request",
      "command" => get_in(p, ["toolCall", "rawInput", "command"]),
      "options" => p["options"] || [],
      "resolved" => false
    }

    {%{state | perms: Map.put(state.perms, "perm-#{id}", id)}, [item], [], []}
  end

  # --- session/update reduction (agent->client notifications) ---

  defp dispatch_incoming(state, %{"method" => "session/update", "params" => %{"update" => u}}) do
    {state, item} = reduce_update(state, u, u["sessionUpdate"])
    if item, do: {state, [item], [], []}, else: {state, [], [], []}
  end

  defp dispatch_incoming(state, _msg), do: {state, [], [], []}

  defp reduce_update(state, u, "agent_message_chunk") do
    state = mark_agent_output(state)
    accumulate(state, "msg-#{state.turn}", "message", %{"role" => "assistant"}, text(u))
  end

  defp reduce_update(state, u, "agent_thought_chunk") do
    state = mark_agent_output(state)
    accumulate(state, "thought-#{state.turn}", "thought", %{}, text(u))
  end

  defp reduce_update(state, u, "user_message_chunk") do
    # Turn-boundary detection (I4): a user message that FOLLOWS agent output in
    # the notification stream begins a new turn. This is how session/load replay
    # — which never calls prompt/2 — produces distinct user-N/msg-N per turn.
    # Consecutive user chunks (no intervening agent output) stay in one turn.
    # Live is unaffected: an agent doesn't echo our own prompt as user chunks.
    state =
      if state.turn_seen_response do
        %{state | turn: state.turn + 1, turn_seen_response: false}
      else
        state
      end

    accumulate(state, "user-#{state.turn}", "message", %{"role" => "user"}, text(u))
  end

  defp reduce_update(state, u, kind) when kind in ["tool_call", "tool_call_update"] do
    state = mark_agent_output(state)
    id = u["toolCallId"]
    prev = Map.get(state.reduce, id, %{"id" => id, "type" => "tool"})

    item =
      prev
      |> merge_present(u, "title")
      |> merge_present(u, "kind")
      |> merge_present(u, "status")
      |> put_tool_content(u["content"])

    # I9: once a tool reaches a terminal status, drop it from the working set
    # AFTER emitting the final item. The AcpTimeline holds the canonical copy by
    # id; a later stray update just rebuilds a bare base entry (acceptable).
    reduce =
      if item["status"] in ["completed", "failed"] do
        Map.delete(state.reduce, id)
      else
        Map.put(state.reduce, id, item)
      end

    {%{state | reduce: reduce}, item}
  end

  defp reduce_update(state, u, "plan"),
    do: {state, %{"id" => "plan", "type" => "plan", "entries" => plan_entries(u["entries"])}}

  defp reduce_update(state, u, "available_commands_update"),
    do:
      {state,
       %{"id" => "commands", "type" => "commands", "commands" => u["availableCommands"] || []}}

  defp reduce_update(state, u, "current_mode_update"),
    do: {state, %{"id" => "mode", "type" => "mode", "mode" => u["currentModeId"]}}

  defp reduce_update(state, _u, _other), do: {state, nil}

  # Record that the current turn has produced agent-side output, so the next
  # user_message_chunk during session/load replay opens a new turn (I4).
  defp mark_agent_output(state), do: %{state | turn_seen_response: true}

  defp accumulate(state, id, type, base, chunk) do
    prev = Map.get(state.reduce, id, Map.merge(%{"id" => id, "type" => type, "text" => ""}, base))
    item = %{prev | "text" => prev["text"] <> chunk}
    {%{state | reduce: Map.put(state.reduce, id, item)}, item}
  end

  defp text(%{"content" => %{"text" => t}}) when is_binary(t), do: t
  defp text(_), do: ""

  defp merge_present(item, u, key) do
    case u[key] do
      nil -> item
      v -> Map.put(item, key, v)
    end
  end

  defp put_tool_content(item, nil), do: item

  defp put_tool_content(item, content) when is_list(content) do
    diff = Enum.find(content, &(&1["type"] == "diff"))

    text =
      content
      |> Enum.filter(&(&1["type"] in ["content", "text"]))
      |> Enum.map_join("", &(get_in(&1, ["content", "text"]) || &1["text"] || ""))

    # Only overwrite "diff" when THIS update carries one — a later content-only
    # update must not erase a diff set by an earlier tool_call(_update).
    item
    |> then(fn item ->
      if diff,
        do: Map.put(item, "diff", Map.take(diff, ["path", "oldText", "newText"])),
        else: item
    end)
    |> Map.update("output", cap_output(text), &cap_output(&1 <> text))
  end

  # Bound accumulated tool output to @max_tool_output bytes, keeping the tail
  # (most recent output) behind a leading truncation marker (I9).
  defp cap_output(output) when byte_size(output) <= @max_tool_output, do: output

  defp cap_output(output) do
    keep = @max_tool_output - byte_size(@tool_output_truncation_marker)
    tail = binary_part(output, byte_size(output) - keep, keep)
    @tool_output_truncation_marker <> tail
  end

  defp plan_entries(nil), do: []

  defp plan_entries(entries),
    do: Enum.map(entries, &%{"text" => &1["content"] || &1["title"], "status" => &1["status"]})
end
