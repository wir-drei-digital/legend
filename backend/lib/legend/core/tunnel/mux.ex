defmodule Legend.Core.Tunnel.Mux do
  @moduledoc """
  Stream-multiplexing frame codec shared with the in-sprite bridge
  (`bridge/src/mux.rs` — keep both in lockstep).

  Wire: big-endian `type:u8 stream_id:u32 length:u32 payload:length`.
  Types: 1 OPEN, 2 DATA, 3 CLOSE, 4 WINDOW (payload = credit:u32).
  """

  @initial_window 262_144
  def initial_window, do: @initial_window

  defmodule Frame do
    @enforce_keys [:type, :stream_id]
    defstruct [:type, :stream_id, payload: ""]

    @type t :: %__MODULE__{
            type: :open | :data | :close | :window,
            stream_id: non_neg_integer(),
            payload: binary()
          }
  end

  @tag %{open: 1, data: 2, close: 3, window: 4}
  @type_of %{1 => :open, 2 => :data, 3 => :close, 4 => :window}

  @spec encode(Frame.t()) :: binary()
  def encode(%Frame{type: type, stream_id: id, payload: p}) do
    <<Map.fetch!(@tag, type), id::32, byte_size(p)::32, p::binary>>
  end

  @doc "Consume as many whole frames as `buffer` holds; return {frames, leftover}."
  @spec decode(binary()) :: {[Frame.t()], binary()}
  def decode(buffer), do: decode(buffer, [])

  defp decode(<<tag, id::32, len::32, payload::binary-size(len), rest::binary>>, acc) do
    decode(rest, [%Frame{type: Map.fetch!(@type_of, tag), stream_id: id, payload: payload} | acc])
  end

  defp decode(leftover, acc), do: {Enum.reverse(acc), leftover}

  @spec window(non_neg_integer(), non_neg_integer()) :: Frame.t()
  def window(stream_id, credit),
    do: %Frame{type: :window, stream_id: stream_id, payload: <<credit::32>>}

  @spec parse_window(Frame.t()) :: {:window, non_neg_integer(), non_neg_integer()}
  def parse_window(%Frame{type: :window, stream_id: id, payload: <<credit::32>>}),
    do: {:window, id, credit}
end
