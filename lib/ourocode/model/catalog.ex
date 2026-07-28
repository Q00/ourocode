defmodule Ourocode.Model.Catalog do
  @moduledoc """
  Detects the selectable backends, the way an installer probes a machine.

  Probes are injectable so the detection logic is pure and unit-tested:

    * `:codex_signed_in` boolean (default: `Provider.Codex.signed_in?/0`)
    * `:which`           `name -> path | nil` (default: `System.find_executable/1`)

  Codex and Claude are listed through direct transports. Slow agent CLI
  subprocess backends are intentionally not used for those providers.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Conversation
  alias Ourocode.Provider.Anthropic
  alias Ourocode.Provider.Anthropic.Client, as: AnthropicClient
  alias Ourocode.Provider.Anthropic.Messages, as: AnthropicMessages
  alias Ourocode.Provider.Codex
  alias Ourocode.Provider.Codex.Client

  @ouroboros_config_path Path.expand("~/.ouroboros/config.yaml")

  @cli_labels %{gemini: "gemini cli"}

  @doc "All backends with detected status: direct-API providers, then CLIs."
  @spec list(keyword()) :: [Model.t()]
  def list(opts \\ []) do
    which = Keyword.get(opts, :which, &System.find_executable/1)
    cli_stream = Keyword.get(opts, :cli_stream, &Ourocode.Model.Cli.stream/4)
    codex_signed_in? = Keyword.get_lazy(opts, :codex_signed_in, &Codex.signed_in?/0)
    anthropic_signed_in? = Keyword.get_lazy(opts, :anthropic_signed_in, &Anthropic.signed_in?/0)

    [
      codex_model(codex_signed_in?),
      claude_api_model(anthropic_signed_in?)
      | cli_models(which, cli_stream)
    ]
  end

  @doc """
  Picks the default active model.

  When Ouroboros has a configured runtime backend, ourocode follows that
  backend first so the main session and MCP interview runtime do not silently
  split across providers. If no shared preference is available, fall back to
  Codex when ready, then any remaining ready non-agent CLI, then Codex for
  `/login`.
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

  @doc "Provider-specific model slugs available for a backend provider."
  @spec provider_model_slugs(atom()) :: [map()]
  defdelegate provider_model_slugs(provider_id), to: Ourocode.Model.ProviderModels

  @doc "Built-in default model slug for a backend provider."
  @spec default_provider_model_slug(atom()) :: String.t() | nil
  defdelegate default_provider_model_slug(provider_id), to: Ourocode.Model.ProviderModels

  @doc "Looks up a provider-specific model slug after normalizing user input."
  @spec fetch_provider_model_slug(atom(), term()) :: map() | nil
  defdelegate fetch_provider_model_slug(provider_id, slug), to: Ourocode.Model.ProviderModels

  @doc """
  Validates a provider-specific model slug.

  Built-in slugs must be present in `provider_model_slugs/1`. Tests and future
  provider migration paths may pass `allow_custom?: true` to store a nonblank
  slug without making it the global default or adding it to the catalog.
  """
  @spec validate_provider_model_slug(atom(), term(), keyword()) ::
          {:ok, String.t()}
          | {:error, :unknown_provider | :invalid_slug | :blank_slug | :unknown_slug}
  defdelegate validate_provider_model_slug(provider_id, slug, opts \\ []),
    to: Ourocode.Model.ProviderModels

  defp codex_model(signed_in?) do
    %Model{
      id: :codex,
      label: "codex  (ChatGPT)",
      kind: :oauth,
      status: if(signed_in?, do: :ready, else: {:needs_auth, "/login"}),
      run: fn prompt, opts, on_chunk ->
        {conversation, opts} = Keyword.pop(opts, :history)

        opts =
          case conversation do
            %Conversation{} ->
              Keyword.put(opts, :input, Conversation.input_items(conversation, prompt))

            _none ->
              opts
          end

        Client.stream(prompt, opts, on_chunk)
      end
    }
  end

  defp claude_api_model(signed_in?) do
    %Model{
      id: :claude_api,
      label: "claude  (Claude Pro/Max)",
      kind: :oauth,
      status: if(signed_in?, do: :ready, else: {:needs_auth, "/login-claude"}),
      run: fn prompt, opts, on_chunk ->
        {conversation, opts} = Keyword.pop(opts, :history)

        opts =
          case conversation do
            %Conversation{} ->
              turns = Conversation.budgeted_pairs(conversation)
              Keyword.put(opts, :input, AnthropicMessages.messages(turns, prompt))

            _none ->
              opts
          end

        AnthropicClient.stream(prompt, opts, on_chunk)
      end
    }
  end

  defp cli_models(which, cli_stream) do
    Ourocode.Model.Cli.specs()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn id ->
      installed? = Ourocode.Model.Cli.resolve(id, which) != nil

      %Model{
        id: id,
        label: Map.get(@cli_labels, id, to_string(id)),
        kind: :cli,
        status: if(installed?, do: :ready, else: :unavailable),
        run: fn prompt, opts, on_chunk ->
          {conversation, opts} = Keyword.pop(opts, :history)

          prompt =
            case conversation do
              %Conversation{} -> Conversation.render_prompt(conversation, prompt)
              _none -> prompt
            end

          cli_stream.(id, prompt, Keyword.put(opts, :which, which), on_chunk)
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
    candidates = opts |> ouroboros_backend() |> backend_model_ids()

    ready_candidate(models, candidates) || selectable_candidate(models, candidates)
  end

  # Candidates are ordered fastest-first (direct API before CLI subprocess:
  # a spawned CLI pays multi-second startup on every turn for the same
  # provider account), so the first ready candidate wins. When none is
  # ready, fall back to the first selectable one so auth hints still show.
  defp ready_candidate(models, candidates) do
    Enum.find_value(candidates, fn id ->
      case fetch(models, id) do
        %Model{} = model -> if Model.ready?(model), do: model
        nil -> nil
      end
    end)
  end

  defp selectable_candidate(models, candidates) do
    Enum.find_value(candidates, fn id ->
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
      path
      |> File.read()
      |> case do
        {:ok, text} -> backend_from_ouroboros_config_text(text)
        {:error, _reason} -> nil
      end
    end
  end

  defp read_ouroboros_backend(_path), do: nil

  defp backend_from_ouroboros_config_text(text) when is_binary(text) do
    sections =
      text
      |> String.split(~r/\R/)
      |> Enum.reduce(%{current: nil, values: %{}}, &scan_ouroboros_backend_line/2)

    sections.values[:orchestrator] || sections.values[:llm]
  end

  defp backend_from_ouroboros_config_text(_text), do: nil

  defp scan_ouroboros_backend_line(line, %{current: current, values: values} = acc) do
    trimmed = strip_yaml_comment(line)

    cond do
      trimmed == "" ->
        acc

      top = Regex.run(~r/^([A-Za-z0-9_-]+):\s*$/, trimmed) ->
        %{acc | current: Enum.at(top, 1)}

      current == "orchestrator" ->
        case yaml_scalar_value(trimmed, "runtime_backend") do
          nil -> acc
          backend -> %{acc | values: Map.put(values, :orchestrator, normalize_backend(backend))}
        end

      current == "llm" ->
        case yaml_scalar_value(trimmed, "backend") do
          nil -> acc
          backend -> %{acc | values: Map.put(values, :llm, normalize_backend(backend))}
        end

      true ->
        acc
    end
  end

  defp strip_yaml_comment(line) do
    line
    |> String.replace(~r/\s+#.*$/, "")
    |> String.trim()
  end

  defp yaml_scalar_value(line, key) do
    case Regex.run(~r/^#{Regex.escape(key)}:\s*(.+?)\s*$/, line) do
      [_, value] -> value |> String.trim() |> String.trim(~s("')) |> String.trim()
      _no_match -> nil
    end
  end

  defp normalize_backend(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_backend()

  defp normalize_backend(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.trim()
  end

  defp normalize_backend(_value), do: nil

  defp backend_model_ids("codex"), do: [:codex]
  defp backend_model_ids("claude"), do: [:claude_api]
  defp backend_model_ids("claude_api"), do: [:claude_api]
  defp backend_model_ids("gemini"), do: [:gemini]
  defp backend_model_ids("gemini_cli"), do: [:gemini]
  defp backend_model_ids(_backend), do: []
end
