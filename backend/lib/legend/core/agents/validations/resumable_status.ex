defmodule Legend.Core.Agents.Validations.ResumableStatus do
  @moduledoc """
  Resume is only valid from a stopped-but-resumable state. Reads the RECORD's
  current status (changeset.data) — the action itself rewrites :status, so the
  changeset value is useless here.
  """

  use Ash.Resource.Validation

  @resumable [:interrupted, :exited]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.status in @resumable do
      :ok
    else
      {:error, field: :status, message: "can only resume an interrupted or exited session"}
    end
  end
end
