defmodule Legend.Core.Library.Seeder do
  @moduledoc """
  Boot-time library seeding. Runs synchronously in start_link (the
  supervisor's own process), so a raise aborts boot loudly; on success there
  is nothing to supervise and it returns :ignore. Placed after the Migrator
  so the settings table is readable for root resolution.
  """

  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary, type: :worker}
  end

  def start_link do
    Legend.Core.Library.ensure_seeded!()
    :ignore
  end
end
