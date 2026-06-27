defmodule Relay.RegistryTest do
  use ExUnit.Case, async: false

  setup do
    # allowlist for the test: handle "laptop" => secret "s3cret"
    Application.put_env(:relay, :handles, %{"laptop" => "s3cret"})
    start_supervised!(Relay.Registry)
    :ok
  end

  test "valid registration, then lookup" do
    assert :ok = Relay.Registry.register("laptop", "s3cret", self())
    assert {:ok, pid} = Relay.Registry.lookup("laptop")
    assert pid == self()
  end

  test "wrong secret is rejected" do
    assert {:error, :bad_secret} = Relay.Registry.register("laptop", "nope", self())
  end

  test "unknown handle is rejected" do
    assert {:error, :bad_secret} = Relay.Registry.register("ghost", "x", self())
  end

  test "invalid DNS-label handle is rejected before any secret check" do
    assert {:error, :bad_handle} = Relay.Registry.register("Not_A_Label", "s3cret", self())
    refute Relay.Registry.handle_valid?("Not_A_Label")
    assert Relay.Registry.handle_valid?("laptop")
  end

  test "a trailing newline is rejected (\\A…\\z, not ^…$)" do
    # PCRE $ matches before a trailing newline, so "laptop\n" would slip past ^…$.
    refute Relay.Registry.handle_valid?("laptop\n")
    assert Relay.Registry.handle_valid?("laptop")
  end

  test "a second live registration of the same handle is rejected" do
    other = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = Relay.Registry.register("laptop", "s3cret", other)
    assert {:error, :taken} = Relay.Registry.register("laptop", "s3cret", self())
  end

  test "registration is cleared when the carrier dies" do
    pid = spawn(fn -> Process.sleep(50) end)
    assert :ok = Relay.Registry.register("laptop", "s3cret", pid)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    Process.sleep(20)
    assert :error = Relay.Registry.lookup("laptop")
  end
end
