defmodule Legend.Core.Library.SeederTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Library.Seeder

  @moduletag :tmp_dir

  setup do
    original = Application.get_env(:legend, :library_path)
    on_exit(fn -> Application.put_env(:legend, :library_path, original) end)
    :ok
  end

  test "start_link seeds the effective root and returns :ignore", %{tmp_dir: tmp} do
    Application.put_env(:legend, :library_path, tmp)
    assert :ignore = Seeder.start_link()
    assert File.dir?(Path.join(tmp, "knowledge"))
  end

  test "start_link raises (aborting boot) on an unusable root" do
    Application.put_env(:legend, :library_path, "/dev/null/nope")
    assert_raise RuntimeError, ~r/unusable/, fn -> Seeder.start_link() end
  end

  test "start_link seeds the SETTING path when env is absent", %{tmp_dir: tmp} do
    Application.put_env(:legend, :library_path, nil)
    Legend.Core.Settings.put_setting!(%{key: "library_path", value: tmp})

    assert :ignore = Seeder.start_link()
    assert File.dir?(Path.join(tmp, "artifacts"))
  end
end
