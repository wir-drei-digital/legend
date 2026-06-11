defmodule Legend.Core.Agents.Validations.KnownRegistryId do
  @moduledoc """
  Validates that a string attribute matches a registered plugin id. Ids stay
  strings throughout — user input is never converted to an atom.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    if Keyword.has_key?(opts, :attribute) and Keyword.has_key?(opts, :registry) do
      {:ok, opts}
    else
      {:error, "requires :attribute and :registry options"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute]

    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil ->
        :ok

      id ->
        case opts[:registry].fetch(id) do
          {:ok, _module} -> :ok
          :error -> {:error, field: attribute, message: "is not a registered id"}
        end
    end
  end
end
