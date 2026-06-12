defmodule Legend.Harnesses.Hermes.McpSetupTest do
  use ExUnit.Case, async: true

  alias Legend.Core.Harness.Setup
  alias Legend.Harnesses.Hermes.McpSetup

  @entry %{
    "url" => "${LEGEND_MCP_URL}",
    "headers" => %{"Authorization" => "Bearer ${LEGEND_SESSION_TOKEN}"}
  }

  defp config_path(home), do: Path.join(home, "config.yaml")

  test "nonexistent home dir is not_applicable", %{} do
    assert %Setup{status: :not_applicable} = McpSetup.setup("/nonexistent/hermes-home")
  end

  @tag :tmp_dir
  test "home dir without config.yaml is missing; apply creates the file", %{tmp_dir: home} do
    assert %Setup{status: :missing, summary: summary, restart_hint: true} = McpSetup.setup(home)
    assert summary =~ "config.yaml"

    assert :ok = McpSetup.apply_setup(home)
    assert %Setup{status: :ok} = McpSetup.setup(home)

    {:ok, config} = YamlElixir.read_from_file(config_path(home))
    assert config["mcp_servers"]["legend"] == @entry
  end

  @tag :tmp_dir
  test "apply preserves unrelated config and writes a backup", %{tmp_dir: home} do
    File.write!(config_path(home), """
    default_model: anthropic/claude-sonnet-4
    mcp_servers:
      time:
        command: uvx
        args: ["mcp-server-time"]
    """)

    assert %Setup{status: :missing} = McpSetup.setup(home)
    assert :ok = McpSetup.apply_setup(home)

    {:ok, config} = YamlElixir.read_from_file(config_path(home))
    assert config["default_model"] == "anthropic/claude-sonnet-4"
    assert config["mcp_servers"]["time"]["command"] == "uvx"
    assert config["mcp_servers"]["legend"] == @entry

    backup = config_path(home) <> ".legend-backup"
    assert File.read!(backup) =~ "default_model: anthropic/claude-sonnet-4"
    refute File.read!(backup) =~ "legend"
  end

  @tag :tmp_dir
  test "existing legend entry is ok; apply is idempotent", %{tmp_dir: home} do
    File.write!(config_path(home), """
    mcp_servers:
      legend:
        url: ${LEGEND_MCP_URL}
        headers:
          Authorization: Bearer ${LEGEND_SESSION_TOKEN}
    """)

    assert %Setup{status: :ok} = McpSetup.setup(home)
    assert :ok = McpSetup.apply_setup(home)
    assert %Setup{status: :ok} = McpSetup.setup(home)

    {:ok, config} = YamlElixir.read_from_file(config_path(home))
    assert config["mcp_servers"]["legend"] == @entry
  end

  @tag :tmp_dir
  test "malformed yaml is error with manual snippet; apply refuses and leaves the file alone",
       %{tmp_dir: home} do
    File.write!(config_path(home), "mcp_servers: [unclosed\n  bad: {indent")
    original = File.read!(config_path(home))

    assert %Setup{status: :error, detail: detail} = McpSetup.setup(home)
    assert detail =~ "mcp_servers:"
    assert detail =~ "${LEGEND_MCP_URL}"

    assert {:error, _reason} = McpSetup.apply_setup(home)
    assert File.read!(config_path(home)) == original
    refute File.exists?(config_path(home) <> ".legend-backup")
  end

  @tag :tmp_dir
  test "config that parses to a non-map is error", %{tmp_dir: home} do
    File.write!(config_path(home), "- just\n- a\n- list\n")
    assert %Setup{status: :error} = McpSetup.setup(home)
    assert {:error, _} = McpSetup.apply_setup(home)
  end

  @tag :tmp_dir
  test "apply on a nonexistent home errors", %{tmp_dir: home} do
    missing = Path.join(home, "nope")
    assert {:error, reason} = McpSetup.apply_setup(missing)
    assert reason =~ "not found"
  end
end
