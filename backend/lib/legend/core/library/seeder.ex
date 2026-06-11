defmodule Legend.Core.Library.Seeder do
  @moduledoc "Boot task: create the library root and convention dirs (idempotent)."

  use Task, restart: :temporary

  def start_link(_arg), do: Task.start_link(&Legend.Core.Library.ensure_seeded!/0)
end
