defmodule Legend.Core.Settings do
  @moduledoc """
  Key-value settings persisted in SQLite. Not exposed via JSON:API — settings
  have bespoke semantics (validation, side effects), served by dedicated
  controllers. Well-known keys: "library_path".
  """

  use Ash.Domain, otp_app: :legend

  resources do
    resource Legend.Core.Settings.Setting do
      define :put_setting, action: :put
      define :delete_setting_record, action: :destroy
      define :get_setting_record, action: :read, get_by: [:key]
    end
  end

  @doc "Returns the stored value, nil when absent. Raises on genuine store failures (fail-loud)."
  def get_setting(key) when is_binary(key) do
    case get_setting_record(key) do
      {:ok, %{value: value}} ->
        value

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
          nil
        else
          raise error
        end

      {:error, error} ->
        raise error
    end
  end

  @doc "Removes a setting; no-op when absent."
  def remove_setting(key) when is_binary(key) do
    case get_setting_record(key) do
      {:ok, record} ->
        delete_setting_record!(record)
        :ok

      {:error, _} ->
        :ok
    end
  end
end
