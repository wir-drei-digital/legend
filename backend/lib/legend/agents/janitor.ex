defmodule Legend.Agents.Janitor do
  @moduledoc """
  Boot pass: sessions recorded :starting/:running belong to a previous backend
  run (their PTYs died with it) — mark them failed so the UI never shows
  phantom live sessions. Disabled in test (config :legend, run_session_janitor).
  """

  use Task, restart: :temporary

  require Ash.Query

  def start_link(_arg), do: Task.start_link(&run/0)

  def run do
    Legend.Agents.Session
    |> Ash.Query.filter(status in [:starting, :running])
    |> Ash.read!()
    |> Enum.each(&Legend.Agents.fail_session!(&1, %{error: "backend restarted"}))
  end
end
