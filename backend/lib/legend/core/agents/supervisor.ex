defmodule Legend.Core.Agents.Supervisor do
  @moduledoc "Supervises session process infrastructure (registry, dynamic supervisor, janitor)."

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children =
      [
        {Registry, keys: :unique, name: Legend.Core.Agents.SessionRegistry},
        {DynamicSupervisor, name: Legend.Core.Agents.SessionSupervisor, strategy: :one_for_one}
      ] ++ janitor()

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp janitor do
    if Application.get_env(:legend, :run_session_janitor, true) do
      [Legend.Core.Agents.Janitor]
    else
      []
    end
  end
end
