defmodule Legend.Core.Library do
  @moduledoc """
  The shared library: one global tree (knowledge/skills/artifacts) readable and
  writable by every session and the UI. This module is the containment
  chokepoint — every path is validated against the root before touching the
  configured storage adapter. Containment is lexical (Path.expand); the
  symlink-escape caveat is accepted for the single-user local PoC.
  """

  @subdirs ~w(knowledge skills artifacts)

  @readme %{
    "knowledge" =>
      "# Knowledge\n\nDurable notes, research, and reference material. Markdown preferred.\n",
    "skills" =>
      "# Skills\n\nReusable how-tos and scripts agents can follow or execute. One skill per file or folder.\n",
    "artifacts" => "# Artifacts\n\nOutputs worth keeping: generated code, analyses, templates.\n"
  }

  def root do
    case Application.get_env(:legend, :library_path) do
      nil ->
        :user_data |> :filename.basedir("legend") |> Path.join("library")

      path ->
        path
    end
  end

  def primer do
    """
    A shared Legend library lives at $LEGEND_LIBRARY with knowledge/, skills/, and \
    artifacts/ directories (each has a README with its conventions). Before solving \
    a problem from scratch, check the library for existing knowledge or skills. When \
    you produce something reusable (a script, a how-to, a finding), save it there \
    with a descriptive kebab-case filename.
    """
  end

  def ensure_seeded! do
    File.mkdir_p!(root())

    for dir <- @subdirs do
      File.mkdir_p!(Path.join(root(), dir))
      readme = Path.join([root(), dir, "README.md"])
      unless File.exists?(readme), do: File.write!(readme, @readme[dir])
    end

    :ok
  rescue
    e in File.Error ->
      reraise "library root #{inspect(root())} is unusable: #{Exception.message(e)}",
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
