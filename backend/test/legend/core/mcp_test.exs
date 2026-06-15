defmodule Legend.Core.MCPTest do
  use Legend.DataCase, async: false
  alias Legend.Core.MCP

  test "id-less notifications are accepted" do
    assert MCP.handle(%{}, %{"method" => "notifications/initialized"}) == :accepted
  end

  test "initialize returns the server info" do
    assert {:ok, %{result: %{serverInfo: %{name: "legend"}}}} =
             MCP.handle(%{}, %{"method" => "initialize", "id" => 1, "params" => %{}})
  end

  test "tools/list exposes both signal and library tools" do
    {:ok, %{result: %{tools: tools}}} = MCP.handle(%{}, %{"method" => "tools/list", "id" => 2})
    names = Enum.map(tools, &(&1["name"] || &1.name))
    assert "send_message" in names and "library_write" in names
  end

  test "an unknown method returns -32601" do
    assert {:ok, %{error: %{code: -32601}}} =
             MCP.handle(%{}, %{"method" => "nope", "id" => 3})
  end
end
