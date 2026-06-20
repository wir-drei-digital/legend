defprotocol Legend.Core.Agents.Transcript do
  @moduledoc """
  Polymorphic session content store. `append/2` records new content and returns
  the items to broadcast (each carrying a monotonic cursor); `snapshot/1` returns
  the full replay payload plus the cursor at which live items resume. Reattach
  drops broadcast items whose cursor <= the snapshot cursor.
  """
  @spec append(t, term()) :: {t, [term()]}
  def append(transcript, item)

  @spec snapshot(t) :: {term(), non_neg_integer()}
  def snapshot(transcript)
end

defmodule Legend.Core.Agents.AcpTimeline do
  @moduledoc "Ordered, id-keyed timeline of reduced ACP render items."
  defstruct order: [], items: %{}, seq: 0

  def new, do: %__MODULE__{}
end

defimpl Legend.Core.Agents.Transcript, for: Legend.Core.Agents.AcpTimeline do
  alias Legend.Core.Agents.AcpTimeline

  @max_items 5_000

  def append(%AcpTimeline{} = t, %{"id" => id} = item) do
    seq = t.seq + 1
    # MERGE onto an existing same-id item rather than replace: a PARTIAL update
    # (e.g. a resolved permission carrying only resolved/selected) must preserve
    # prior keys like title/command/options while overwriting shared ones + seq.
    # Safe for every other type — the connection emits FULL items for
    # message/thought/tool/plan/commands/mode/nudge, so merge ≈ replace there.
    item =
      case Map.get(t.items, id) do
        nil -> Map.put(item, "seq", seq)
        existing -> existing |> Map.merge(item) |> Map.put("seq", seq)
      end

    order = if Map.has_key?(t.items, id), do: t.order, else: t.order ++ [id]
    t = %{t | items: Map.put(t.items, id, item), order: order, seq: seq} |> trim()
    {t, [item]}
  end

  def snapshot(%AcpTimeline{} = t) do
    {Enum.map(t.order, &Map.fetch!(t.items, &1)), t.seq}
  end

  defp trim(%AcpTimeline{order: order} = t) when length(order) <= @max_items, do: t

  defp trim(%AcpTimeline{order: [drop | rest]} = t),
    do: %{t | order: rest, items: Map.delete(t.items, drop)}
end
