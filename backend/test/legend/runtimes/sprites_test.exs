defmodule Legend.Runtimes.SpritesTest do
  use ExUnit.Case, async: true

  alias Legend.Runtimes.Sprites

  test "id and capabilities" do
    assert Sprites.id() == "sprites"

    assert Sprites.capabilities() == %{
             provisions?: true,
             library: :api,
             tunnel: "sprite_proxy"
           }
  end

  test "the runtime contract is fully implemented" do
    # function_exported?/3 reports false for an unloaded module.
    Code.ensure_loaded!(Sprites)

    for {fun, arity} <- [
          id: 0,
          capabilities: 0,
          start: 2,
          write: 2,
          resize: 3,
          stop: 1,
          exec: 2,
          attach: 2,
          teardown: 1
        ] do
      assert function_exported?(Sprites, fun, arity), "missing #{fun}/#{arity}"
    end
  end
end
