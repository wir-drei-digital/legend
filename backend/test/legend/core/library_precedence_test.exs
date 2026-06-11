defmodule Legend.Core.LibraryPrecedenceTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Library
  alias Legend.Core.Settings

  @moduletag :tmp_dir

  setup do
    original = Application.get_env(:legend, :library_path)
    on_exit(fn -> Application.put_env(:legend, :library_path, original) end)
    :ok
  end

  test "env override wins over setting and default", %{tmp_dir: tmp} do
    Application.put_env(:legend, :library_path, tmp)
    Settings.put_setting!(%{key: "library_path", value: "/tmp/should-not-win"})

    assert Library.root() == tmp
    assert %{source: :env, effective: ^tmp} = Library.root_info()
  end

  test "setting wins over default when env is absent", %{tmp_dir: tmp} do
    Application.put_env(:legend, :library_path, nil)
    Settings.put_setting!(%{key: "library_path", value: tmp})

    assert Library.root() == tmp

    assert %{source: :setting, effective: ^tmp, value: ^tmp, default: default} =
             Library.root_info()

    assert default == Library.default_root()
  end

  test "default applies when neither env nor setting exist" do
    Application.put_env(:legend, :library_path, nil)

    assert Library.root() == Library.default_root()
    assert %{source: :default, value: nil} = Library.root_info()
  end

  test "ensure_seeded!/1 seeds an explicit candidate path", %{tmp_dir: tmp} do
    candidate = Path.join(tmp, "candidate")
    assert :ok = Library.ensure_seeded!(candidate)
    assert File.dir?(Path.join(candidate, "skills"))
  end
end
