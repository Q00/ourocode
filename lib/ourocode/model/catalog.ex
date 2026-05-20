defmodule Ourocode.Model.Catalog do
  @moduledoc """
  Detects the selectable backends, the way an installer probes a machine.

  Probes are injectable so the detection logic is pure and unit-tested:

    * `:codex_signed_in` boolean (default: `Provider.Codex.signed_in?/0`)
    * `:which`           `name -> path | nil` (default: `System.find_executable/1`)

  Codex is always listed (selecting it triggers OAuth when not yet signed
  in). CLI backends are listed only when their binary is installed.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Cli
  alias Ourocode.Provider.Codex
  alias Ourocode.Provider.Codex.Client

  @ouroboros_config_path Path.expand("~/.ouroboros/config.yaml")

  @cli_labels %{
    claude: "claude cli",
    codex_cli: "codex cli",
    gemini: "gemini cli"
  }

  @doc "All backends with detected status, Codex first then installed CLIs."
  @spec list(keyword()) :: [Model.t()]
  def list(opts \\ []) do
    which = Keyword.get(opts, :which, &System.find_executable/1)
    signed_in? = Keyword.get_lazy(opts, :codex_signed_in, &Codex.signed_in?/0)

    [codex_model(signed_in?) | cli_models(which)]
  end

  @doc """
  Picks the default active model.

  When Ouroboros has a configured runtime backend, ourocode follows that
  backend first so the main session and MCP interview runtime do not silently
  split across providers. If no shared preference is available, fall back to
  Codex when ready, then any ready CLI, then Codex for `/login`.
  """
  @spec default(keyword()) :: Model.t()
  def default(opts \\ []) do
    models = list(opts)

    case preferred_ouroboros_model(models, opts) do
      %Model{} = model -> model
      nil -> fallback_default(models)
    end
  end

  @doc "Looks a model up by id within an already-listed set."
  @spec fetch([Model.t()], atom()) :: Model.t() | nil
  def fetch(models, id), do: Enum.find(models, &(&1.id == id))

  @doc "Selectable rows for the picker (excludes purely unavailable backends)."
  @spec selectable([Model.t()]) :: [Model.t()]
  def selectable(models), do: Enum.reject(models, &(&1.status == :unavailable))

  defp codex_model(signed_in?) do
    %Model{
      id: :codex,
      label: "codex  (ChatGPT)",
      kind: :oauth,
      status: if(signed_in?, do: :ready, else: {:needs_auth, "/login"}),
      run: fn prompt, opts, on_chunk -> Client.stream(prompt, opts, on_chunk) end
    }
  end

  defp cli_models(which) do
    Cli.specs()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn id ->
      installed? = Cli.resolve(id, which) != nil

      %Model{
        id: id,
        label: Map.get(@cli_labels, id, to_string(id)),
        kind: :cli,
        status: if(installed?, do: :ready, else: :unavailable),
        run: fn prompt, opts, on_chunk ->
          Cli.stream(id, prompt, Keyword.put(opts, :which, which), on_chunk)
        end
      }
    end)
  end

  defp fallback_default(models) do
    codex = Enum.find(models, &(&1.id == :codex))

    cond do
      codex && Model.ready?(codex) -> codex
      ready = Enum.find(models, &Model.ready?/1) -> ready
      true -> codex || hd(models)
    end
  end

  defp preferred_ouroboros_model(models, opts) do
    opts
    |> ouroboros_backend()
    |> backend_model_ids()
    |> Enum.find_value(fn id ->
      case fetch(models, id) do
        %Model{status: :unavailable} -> nil
        %Model{} = model -> model
        nil -> nil
      end
    end)
  end

  defp ouroboros_backend(opts) do
    case Keyword.fetch(opts, :ouroboros_backend) do
      {:ok, backend} -> normalize_backend(backend)
      :error -> read_ouroboros_backend(Keyword.get(opts, :ouroboros_config_path, :default))
    end
  end

  defp read_ouroboros_backend(false), do: nil
  defp read_ouroboros_backend(nil), do: nil

  defp read_ouroboros_backend(:default), do: read_ouroboros_backend(@ouroboros_config_path)

  defp read_ouroboros_backend(path) when is_binary(path) do
    if File.regular?(path) do
      case Ourocode.Config.parse_config_file(path) do
        {:ok, %{data: data}} ->
          data
          |> configured_backend()
          |> normalize_backend()

        {:error, _reason} ->
          nil
      end
    end
  end

  defp read_ouroboros_backend(_path), do: nil

  defp configured_backend(data) when is_map(data) do
    get_in(data, ["orchestrator", "runtime_backend"]) ||
      get_in(data, ["llm", "backend"])
  end

  defp configured_backend(_data), do: nil

  defp normalize_backend(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_backend()

  defp normalize_backend(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.trim()
  end

  defp normalize_backend(_value), do: nil

  defp backend_model_ids("codex"), do: [:codex_cli, :codex]
  defp backend_model_ids("codex_cli"), do: [:codex_cli, :codex]
  defp backend_model_ids("claude"), do: [:claude]
  defp backend_model_ids("claude_cli"), do: [:claude]
  defp backend_model_ids("gemini"), do: [:gemini]
  defp backend_model_ids("gemini_cli"), do: [:gemini]
  defp backend_model_ids(_backend), do: []
end
