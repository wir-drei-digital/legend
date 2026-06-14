defmodule Legend.Sprites.Client do
  @moduledoc """
  sprites.dev REST client. `create_sprite`/`get_sprite`/`delete_sprite` are
  live-verified (2026-06-14, used by `Legend.Runtimes.Sprites`). `exec`/`write_file`/
  `chmod` request shapes are UNVERIFIED best-guesses from public docs — note the
  Sprites runtime runs commands over the WSS exec (`Legend.Sprites.Exec`), NOT this
  REST `exec`, which returns the raw binary stream protocol rather than JSON.
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

  # Upload raw bytes to `path` (fs API, verified 2026-06-14): PUT /fs/write with the
  # path/mode/mkdir as query params and the file's raw bytes as the body. `mode`
  # sets permissions at write time, so no separate chmod is needed for the bridge.
  def write_file(name, path, content, mode \\ "0755") when is_binary(content) do
    qs = URI.encode_query(%{"path" => path, "mode" => mode, "mkdir" => "true"})
    request(:put, "/sprites/#{name}/fs/write?#{qs}", body: content)
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
