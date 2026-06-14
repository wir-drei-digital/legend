defmodule Legend.Core.Library.ToolsTest do
  use ExUnit.Case, async: false
  alias Legend.Core.Library.Tools

  setup do
    root = Path.join(System.tmp_dir!(), "lib-tools-#{System.unique_integer([:positive])}")
    Application.put_env(:legend, :library_default_root, root)
    Legend.Core.Library.ensure_seeded!(root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.delete_env(:legend, :library_default_root)
    end)

    :ok
  end

  test "list/0 advertises the four library tools" do
    names = Enum.map(Tools.list(), & &1.name)
    assert names == ["library_list", "library_read", "library_write", "library_delete"]
  end

  test "write then read round-trips through the chokepoint" do
    assert {:ok, _} =
             Tools.dispatch("library_write", %{"path" => "knowledge/n.md", "content" => "hi"})

    assert {:ok, "hi"} = Tools.dispatch("library_read", %{"path" => "knowledge/n.md"})
  end

  test "library_list returns the tree as text" do
    assert {:ok, text} = Tools.dispatch("library_list", %{})
    assert text =~ "knowledge"
  end

  test "delete removes a file" do
    Tools.dispatch("library_write", %{"path" => "artifacts/a.txt", "content" => "x"})
    assert {:ok, _} = Tools.dispatch("library_delete", %{"path" => "artifacts/a.txt"})
    assert {:error, msg} = Tools.dispatch("library_read", %{"path" => "artifacts/a.txt"})
    assert is_binary(msg)
  end

  test "path escape is rejected without leaking the absolute path" do
    assert {:error, msg} = Tools.dispatch("library_read", %{"path" => "../../etc/passwd"})
    assert msg =~ "escapes" or msg =~ "outside"
    refute msg =~ System.tmp_dir!()
  end

  test "unknown tool errors" do
    assert {:error, _} = Tools.dispatch("nope", %{})
  end
end
