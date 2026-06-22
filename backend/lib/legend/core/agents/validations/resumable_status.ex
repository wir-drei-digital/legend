defmodule Legend.Core.Agents.Validations.ResumableStatus do
  @moduledoc """
  Resume is only valid from a stopped state. Reads the RECORD's current status
  (changeset.data) — the action itself rewrites :status, so the changeset value
  is useless here.

  Resumable: :interrupted (backend restarted under it), :exited (finished — a
  resume continues the conversation), and :failed (a launch/handshake error is
  recoverable; "Restart" relaunches the run). The live states (:starting,
  :provisioning, :running) are rejected.
  """

  use Ash.Resource.Validation

  @resumable [:interrupted, :exited, :failed]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.status in @resumable do
      :ok
    else
      {:error, field: :status, message: "can only resume a stopped session"}
    end
  end
end
