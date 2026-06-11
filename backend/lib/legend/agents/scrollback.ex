defmodule Legend.Agents.Scrollback do
  @moduledoc """
  Bounded byte buffer holding the most recent terminal output for replay on
  (re)attach. Trims whole chunks from the oldest end, but never drops the
  newest chunk, so a single oversized burst is still replayable.
  """

  @default_max_bytes 262_144

  defstruct chunks: :queue.new(), bytes: 0, max_bytes: @default_max_bytes

  @type t :: %__MODULE__{}

  @spec new(pos_integer()) :: t()
  def new(max_bytes \\ @default_max_bytes), do: %__MODULE__{max_bytes: max_bytes}

  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{} = sb, data) when is_binary(data) do
    trim(%{sb | chunks: :queue.in(data, sb.chunks), bytes: sb.bytes + byte_size(data)})
  end

  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{chunks: chunks}) do
    chunks |> :queue.to_list() |> IO.iodata_to_binary()
  end

  defp trim(%{bytes: bytes, max_bytes: max} = sb) when bytes <= max, do: sb

  defp trim(sb) do
    if :queue.len(sb.chunks) <= 1 do
      sb
    else
      {{:value, oldest}, rest} = :queue.out(sb.chunks)
      trim(%{sb | chunks: rest, bytes: sb.bytes - byte_size(oldest)})
    end
  end
end
