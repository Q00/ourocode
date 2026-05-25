defmodule Ourocode.Plugin.UserLevel.PreflightResult do
  @moduledoc """
  Read-only resolution result for an `ooo <plugin> <command> ...`-shaped
  prompt.

  A `PreflightResult` records *what would happen* if dispatch proceeded:
  which UserLevel plugin and command were matched, which arguments were
  parsed, what trust state applies, what artifacts the command is expected
  to produce, and which continuation policy governs follow-up workflows.

  The result itself never executes anything. The dispatch adapter consumes
  the result; the TUI renders it; the journal records it.
  """

  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Plugin.UserLevel.Capability.Command, as: CommandCapability

  @type kind ::
          :unique_match
          | :ambiguous
          | :unknown
          | :not_applicable

  @type trust_state :: :allowed | :missing | :unknown
  @type continuation_policy :: :none | :suggest | :auto_when_requested
  @type confidence :: :exact | :alias | :none

  @type match_explanation :: %{
          required(:matched_by) => :canonical | :alias | nil,
          required(:confidence) => confidence(),
          optional(:reason) => atom()
        }

  @type t :: %__MODULE__{
          kind: kind(),
          task_input: String.t(),
          plugin: Capability.t() | nil,
          command: CommandCapability.t() | nil,
          args: [String.t()],
          trust_state: trust_state(),
          remediation: String.t() | nil,
          risk_class: CommandCapability.risk_class(),
          expected_artifacts: [String.t()],
          continuation_policy: continuation_policy(),
          candidates: [Capability.t()],
          match_explanation: match_explanation(),
          reason: atom() | nil
        }

  defstruct kind: :unknown,
            task_input: "",
            plugin: nil,
            command: nil,
            args: [],
            trust_state: :unknown,
            remediation: nil,
            risk_class: :unknown,
            expected_artifacts: [],
            continuation_policy: :none,
            candidates: [],
            match_explanation: %{matched_by: nil, confidence: :none},
            reason: nil

  @doc """
  Convenience constructor used by the resolver to ensure default fields stay
  consistent across kinds.
  """
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields) do
    struct(__MODULE__, fields)
  end
end
