defmodule Ourocode.Plugin.UserLevel.PreflightResultTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.UserLevel.PreflightResult

  test "new/1 fills defaults for unspecified fields" do
    result = PreflightResult.new(kind: :unknown, task_input: "x")

    assert %PreflightResult{
             kind: :unknown,
             task_input: "x",
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
           } = result
  end
end
