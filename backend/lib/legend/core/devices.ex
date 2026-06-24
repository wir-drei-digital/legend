defmodule Legend.Core.Devices do
  @moduledoc """
  Device identity for remote access: paired devices, pairing codes, and an audit
  trail. Carries the `AshJsonApi.Domain` extension (required of every registered
  domain) but exposes no JSON:API routes — access is via plain controllers.
  """
  use Ash.Domain, otp_app: :legend, extensions: [AshJsonApi.Domain]

  alias Legend.Core.Devices.{Device, PairingCode}

  resources do
    resource Device do
      define :create_device, action: :pair
      define :get_device_record, action: :read, get_by: :id
      define :list_devices, action: :list
      define :touch_device, action: :touch
      define :revoke_device, action: :revoke
    end

    resource PairingCode do
      define :generate_pairing_code, action: :generate
      define :pairing_code_by_code, action: :by_code, args: [:code]
      define :mark_pairing_code_redeemed, action: :mark_redeemed
    end
  end

  @doc "Fetch a device by id; `{:error, :not_found}` when absent."
  def get_device(id) do
    case get_device_record(id) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, device} ->
        {:ok, device}

      # AshSqlite raises NotFound (wrapped in Ash.Error.Invalid) for a missing
      # get_by rather than returning {:ok, nil}; normalize it to the stable
      # {:error, :not_found} contract DeviceToken depends on. Genuine store
      # failures still propagate (fail-loud).
      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
          {:error, :not_found}
        else
          {:error, error}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Redeem a code, minting a paired device. Single-use and TTL-bounded:
  `{:error, :invalid | :expired | :used}` on the unhappy paths.
  """
  def redeem_pairing_code(code, attrs) when is_binary(code) do
    case pairing_code_by_code(code) do
      {:ok, %PairingCode{redeemed_at: redeemed}} when not is_nil(redeemed) ->
        {:error, :used}

      {:ok, %PairingCode{expires_at: exp} = pc} ->
        if DateTime.compare(exp, DateTime.utc_now()) == :gt do
          _ = mark_pairing_code_redeemed!(pc)
          {:ok, create_device!(Map.take(attrs, [:name, :public_key]))}
        else
          {:error, :expired}
        end

      _ ->
        {:error, :invalid}
    end
  end
end
