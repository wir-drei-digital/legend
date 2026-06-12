defmodule Legend.Harnesses.Hermes.McpSetup do
  @moduledoc """
  One-time Legend MCP registration in Hermes' config (`$HERMES_HOME/config.yaml`,
  default `~/.hermes`). Hermes has no per-launch MCP flag; it resolves `${VAR}`
  placeholders from each spawned process's environment, so a single static
  entry serves every session with its own per-session identity token. The
  placeholders below are LITERAL — never substitute real values into the file.

  Apply does a YAML round-trip (accepted tradeoff: comments/key order are lost,
  same as Hermes' own `hermes mcp add`), with `config.yaml.legend-backup`
  written first and an atomic tmp+rename write.
  """

  alias Legend.Core.Harness.Setup

  @entry %{
    "url" => "${LEGEND_MCP_URL}",
    "headers" => %{"Authorization" => "Bearer ${LEGEND_SESSION_TOKEN}"}
  }

  @manual_snippet """
  mcp_servers:
    legend:
      url: ${LEGEND_MCP_URL}
      headers:
        Authorization: Bearer ${LEGEND_SESSION_TOKEN}
  """

  @spec setup(Path.t()) :: Setup.t()
  def setup(home \\ home()) do
    cond do
      not File.dir?(home) ->
        %Setup{status: :not_applicable}

      not File.exists?(config_path(home)) ->
        %Setup{status: :missing, summary: summary(home), restart_hint: true}

      true ->
        case read_config(home) do
          {:ok, config} ->
            status = if get_in(config, ["mcp_servers", "legend"]), do: :ok, else: :missing
            %Setup{status: status, summary: summary(home), restart_hint: true}

          {:error, reason} ->
            %Setup{
              status: :error,
              summary: summary(home),
              detail: error_detail(home, reason),
              restart_hint: true
            }
        end
    end
  end

  # Backup comes after put_entry: a refused apply must leave no backup file.
  @spec apply_setup(Path.t()) :: :ok | {:error, String.t()}
  def apply_setup(home \\ home()) do
    path = config_path(home)

    with :ok <- ensure_home(home),
         {:ok, config} <- read_config_or_empty(home),
         {:ok, updated} <- put_entry(config),
         :ok <- backup(path),
         :ok <- write_atomically(path, Ymlr.document!(updated)) do
      :ok
    end
  end

  defp home do
    Application.get_env(:legend, :hermes_home) ||
      System.get_env("HERMES_HOME") ||
      Path.expand("~/.hermes")
  end

  defp config_path(home), do: Path.join(home, "config.yaml")

  defp summary(home),
    do: "Register Legend's agent tools (MCP) in #{config_path(home)}"

  defp ensure_home(home) do
    if File.dir?(home), do: :ok, else: {:error, "Hermes home not found at #{home}"}
  end

  defp read_config(home) do
    case YamlElixir.read_from_file(config_path(home)) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _other} -> {:error, "config.yaml is not a YAML mapping"}
      {:error, error} -> {:error, error_message(error)}
    end
  end

  defp read_config_or_empty(home) do
    if File.exists?(config_path(home)), do: read_config(home), else: {:ok, %{}}
  end

  # A parseable config can still have a non-map mcp_servers (e.g. a string) —
  # refuse rather than raise.
  defp put_entry(config) do
    case Map.get(config, "mcp_servers") do
      servers when is_map(servers) ->
        {:ok, Map.put(config, "mcp_servers", Map.put(servers, "legend", @entry))}

      nil ->
        {:ok, Map.put(config, "mcp_servers", %{"legend" => @entry})}

      _other ->
        {:error, "mcp_servers in config.yaml is not a mapping"}
    end
  end

  defp backup(path) do
    if File.exists?(path) do
      case File.copy(path, path <> ".legend-backup") do
        {:ok, _} -> :ok
        {:error, posix} -> {:error, "backup failed: #{posix}"}
      end
    else
      :ok
    end
  end

  # Same-dir tmp file + rename: readers never observe a half-written config.
  defp write_atomically(path, contents) do
    tmp = path <> ".legend-tmp"

    with :ok <- file_result(File.write(tmp, contents), "write failed"),
         :ok <- file_result(File.rename(tmp, path), "rename failed") do
      :ok
    end
  end

  defp file_result(:ok, _label), do: :ok
  defp file_result({:error, posix}, label), do: {:error, "#{label}: #{posix}"}

  # YamlElixir error tuples normally carry an Exception struct, but fall back to
  # inspect/1 for any shape that isn't one.
  defp error_message(%{__exception__: true} = error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)

  defp error_detail(home, reason) do
    """
    Could not parse #{config_path(home)} (#{reason}).
    Add this entry manually:

    #{@manual_snippet}
    """
  end
end
