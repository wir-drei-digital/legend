defmodule Legend.Core.Signals.Validations.SessionExists do
  @moduledoc "Validates that an attribute references an existing session record."

  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    if is_atom(opts[:attribute]), do: {:ok, opts}, else: {:error, "attribute required"}
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute]

    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil ->
        :ok

      id ->
        case Legend.Core.Agents.get_session(id) do
          {:ok, _session} -> :ok
          {:error, _} -> {:error, field: attribute, message: "unknown session"}
        end
    end
  end
end
