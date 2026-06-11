defmodule Legend.Core.Library.Storage do
  @moduledoc """
  Adapter seam for library storage. Exactly one adapter is active, selected by
  `config :legend, :library_storage`. Paths are RELATIVE to the library root —
  containment is the chokepoint's (`Legend.Core.Library`) job, not the adapter's.
  `Legend.Storage.LocalDisk` is the local implementation; a cloud/synced
  adapter later implements the same callbacks.
  """

  @type entry :: %{
          path: String.t(),
          type: :file | :dir,
          size: non_neg_integer(),
          mtime: DateTime.t()
        }

  @callback list_tree(root :: String.t()) :: {:ok, [entry()]} | {:error, term()}
  @callback read(root :: String.t(), rel_path :: String.t()) ::
              {:ok, binary()} | {:error, term()}
  @callback write(root :: String.t(), rel_path :: String.t(), content :: binary()) ::
              :ok | {:error, term()}
  @callback delete(root :: String.t(), rel_path :: String.t()) :: :ok | {:error, term()}
end
