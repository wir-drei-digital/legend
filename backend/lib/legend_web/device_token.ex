defmodule LegendWeb.DeviceToken do
  @moduledoc """
  Stateless device credential. A `Phoenix.Token` signed with the endpoint's
  `secret_key_base` carries the device id; verification loads the device and
  rejects revoked ones. Secret rotation invalidates all device tokens (re-pair).
  """

  alias Legend.Core.Devices
  alias Legend.Core.Devices.Device

  @salt "device auth"
  # Long-lived: revocation is the kill switch, not expiry. ~10 years.
  @max_age 315_360_000

  @spec sign(String.t()) :: String.t()
  def sign(device_id) when is_binary(device_id) do
    Phoenix.Token.sign(LegendWeb.Endpoint, @salt, device_id)
  end

  @spec verify(String.t()) :: {:ok, struct()} | {:error, :invalid | :revoked}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(LegendWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, device_id} -> load(device_id)
      {:error, _} -> {:error, :invalid}
    end
  end

  def verify(_), do: {:error, :invalid}

  defp load(device_id) do
    case Devices.get_device(device_id) do
      {:ok, %Device{revoked_at: nil} = device} -> {:ok, device}
      {:ok, %Device{}} -> {:error, :revoked}
      {:error, _} -> {:error, :invalid}
    end
  end
end
