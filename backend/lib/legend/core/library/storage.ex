defmodule Legend.Core.Library.Storage do
  @moduledoc """
  Adapter seam for library storage. Exactly one adapter is active, selected by
  `config :legend, :library_storage`. Paths are RELATIVE to the library root —
  containment is the chokepoint's (`Legend.Core.Library`) job, not the adapter's.
  `Legend.Storage.LocalDisk` is the local implementation; a cloud/synced
  adapter later implements the same callbacks.

  Contract notes for adapter authors:
  - `list_tree/1` MUST include a `:dir` entry for every directory that appears
    in any returned path (object stores synthesize them); `size`/`mtime` on
    `:dir` entries are best-effort.
  - `write/3` MUST create missing parent directories; overwrites are
    last-write-wins.
  - `delete/2` removes files only — directories are refused.
  - `read/2` returns raw bytes; text/binary discrimination is the caller's
    concern (the chokepoint validates UTF-8).
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
