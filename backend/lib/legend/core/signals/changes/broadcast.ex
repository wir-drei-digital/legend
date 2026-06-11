defmodule Legend.Core.Signals.Changes.Broadcast do
  @moduledoc "Broadcasts a created message after the transaction commits."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, message} = result ->
        Legend.Core.Signals.Notifications.message_created(message)
        result

      _changeset, error ->
        error
    end)
  end
end
