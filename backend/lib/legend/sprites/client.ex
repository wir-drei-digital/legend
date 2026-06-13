defmodule Legend.Sprites.Client do
  @moduledoc """
  sprites.dev REST client. UNVERIFIED — exec/write_file/chmod request shapes are
  best-guess from public docs; confirm against the live API before relying on them.
  Bearer auth from `config :legend, :sprites_token`.
  """

  @base "https://api.sprites.dev/v1"

  def create_sprite(name, auth \\ "sprite") do
    request(:post, "/sprites", json: %{name: name, url_settings: %{auth: auth}})
  end

  def get_sprite(name), do: request(:get, "/sprites/#{name}")
  def delete_sprite(name), do: request(:delete, "/sprites/#{name}")

  # Non-interactive command. Body shape is a best guess pending live verification.
  def exec(name, %{} = body), do: request(:post, "/sprites/#{name}/exec", json: body)

  # Upload a file. `content` is raw bytes, sent base64. Path/field names best-guess.
  def write_file(name, path, content) when is_binary(content) do
    request(:put, "/sprites/#{name}/fs/file",
      json: %{path: path, content: Base.encode64(content), encoding: "base64"}
    )
  end

  def chmod(name, path, mode),
    do: request(:post, "/sprites/#{name}/fs/chmod", json: %{path: path, mode: mode})

  defp request(method, path, opts \\ []) do
    case token() do
      nil ->
        {:error, "SPRITES_TOKEN is not set"}

      tkn ->
        [method: method, url: @base <> path, auth: {:bearer, tkn}]
        |> Keyword.merge(opts)
        |> Keyword.merge(test_opts())
        |> Req.request()
        |> case do
          {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
          {:ok, %{status: s, body: body}} -> {:error, "sprites #{s}: #{inspect(body)}"}
          {:error, e} -> {:error, Exception.message(e)}
        end
    end
  end

  defp token, do: Application.get_env(:legend, :sprites_token)

  if Mix.env() == :test do
    defp test_opts, do: [plug: {Req.Test, __MODULE__}]
  else
    defp test_opts, do: []
  end
end
