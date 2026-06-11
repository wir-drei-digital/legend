defmodule Legend.Core.SettingsTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Settings

  test "get_setting returns nil for missing keys" do
    assert Settings.get_setting("nope") == nil
  end

  test "put_setting upserts and get_setting reads back" do
    Settings.put_setting!(%{key: "library_path", value: "/tmp/a"})
    assert Settings.get_setting("library_path") == "/tmp/a"

    Settings.put_setting!(%{key: "library_path", value: "/tmp/b"})
    assert Settings.get_setting("library_path") == "/tmp/b"
  end

  test "remove_setting deletes and is idempotent" do
    Settings.put_setting!(%{key: "k", value: "v"})
    assert :ok = Settings.remove_setting("k")
    assert Settings.get_setting("k") == nil
    assert :ok = Settings.remove_setting("k")
  end
end
