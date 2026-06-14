defmodule Legend.Core.Library do
  @moduledoc """
  The shared library: one global tree (knowledge/skills/artifacts) readable and
  writable by every session and the UI. This module is the containment
  chokepoint — every path is validated against the root before touching the
  configured storage adapter. Containment is lexical (Path.expand); the
  symlink-escape caveat is accepted for the single-user local PoC.

  Root resolution: `LIBRARY_PATH` env override > saved setting
  (`Legend.Core.Settings`) > OS default.
  """

  @subdirs ~w(knowledge skills artifacts)

  @readme %{
    "knowledge" =>
      "# Knowledge\n\nDurable notes, research, and reference material. Markdown preferred.\n",
    "skills" =>
      "# Skills\n\nReusable how-tos and scripts agents can follow or execute. One skill per file or folder.\n",
    "artifacts" => "# Artifacts\n\nOutputs worth keeping: generated code, analyses, templates.\n"
  }

  @doc "OS-default library root; overridable in test via config :legend, :library_default_root."
  def default_root do
    Application.get_env(:legend, :library_default_root) ||
      :user_data |> :filename.basedir("legend") |> Path.join("library")
  end

  @doc "Effective root: LIBRARY_PATH env override > saved setting > OS default."
  def root do
    env_root() || setting_root() || default_root()
  end

  @doc "Effective root plus where it came from, for the settings API/UI."
  def root_info do
    source =
      cond do
        env_root() -> :env
        setting_root() -> :setting
        true -> :default
      end

    %{effective: root(), source: source, default: default_root(), value: setting_root()}
  end

  # Set only from the LIBRARY_PATH env var (config/runtime.exs) — the ops override.
  defp env_root, do: Application.get_env(:legend, :library_path)

  defp setting_root, do: Legend.Core.Settings.get_setting("library_path")

  def primer(mode \\ :path)

  def primer(:path) do
    """
    A shared Legend library lives at $LEGEND_LIBRARY with knowledge/, skills/, and \
    artifacts/ directories (each has a README with its conventions). Before solving \
    a problem from scratch, check the library for existing knowledge or skills. When \
    you produce something reusable (a script, a how-to, a finding), save it there \
    with a descriptive kebab-case filename.
    """
  end

  def primer(:api) do
    """
    A shared Legend library (knowledge/, skills/, artifacts/) is available through \
    the library_list / library_read / library_write / library_delete MCP tools. \
    Before solving a problem from scratch, library_list and library_read to check for \
    existing knowledge or skills. When you produce something reusable, library_write \
    it with a descriptive kebab-case path (e.g. artifacts/my-result.md).
    """
  end

  def ensure_seeded!(root_path \\ nil) do
    target = root_path || root()
    File.mkdir_p!(target)

    for dir <- @subdirs do
      File.mkdir_p!(Path.join(target, dir))
      readme = Path.join([target, dir, "README.md"])
      unless File.exists?(readme), do: File.write!(readme, @readme[dir])
    end

    :ok
  rescue
    e in File.Error ->
      reraise "library root #{inspect(root_path || root())} is unusable: #{Exception.message(e)}",
              __STACKTRACE__
  end

  def list_tree, do: storage().list_tree(root())

  def read(rel_path) do
    with {:ok, safe} <- safe_path(rel_path),
         {:ok, content} <- storage().read(root(), safe) do
      if String.valid?(content), do: {:ok, content}, else: {:error, :not_text}
    end
  end

  def write(rel_path, content) when is_binary(content) do
    with {:ok, safe} <- safe_path(rel_path), do: storage().write(root(), safe, content)
  end

  def delete(rel_path) do
    with {:ok, safe} <- safe_path(rel_path), do: storage().delete(root(), safe)
  end

  # Lexical containment: the expanded path must be strictly inside the root.
  defp safe_path(rel_path) when is_binary(rel_path) do
    root = Path.expand(root())
    full = Path.expand(rel_path, root)

    if full != root and String.starts_with?(full, root <> "/") do
      {:ok, Path.relative_to(full, root)}
    else
      {:error, :unsafe_path}
    end
  end

  defp storage, do: Application.get_env(:legend, :library_storage, Legend.Storage.LocalDisk)
end
