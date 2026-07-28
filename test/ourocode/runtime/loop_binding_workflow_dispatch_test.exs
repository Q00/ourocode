defmodule Ourocode.Runtime.LoopBindingWorkflowDispatchTest do
  use ExUnit.Case, async: false

  alias Ourocode.Model
  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Runtime.LoopBindingWorkflowDispatch
  alias Ourocode.Runtime.LoopBindings
  alias Ourocode.TaskRequest

  test "ouroboros_route? detects workflow-routed task requests only" do
    assert LoopBindingWorkflowDispatch.ouroboros_route?(%{
             routing_decision: %{execution_route: :ouroboros_workflow}
           })

    refute LoopBindingWorkflowDispatch.ouroboros_route?(%{
             routing_decision: %{execution_route: :runtime}
           })

    refute LoopBindingWorkflowDispatch.ouroboros_route?(%{})
  end

  test "user_level_route? detects UserLevel plugin task requests only" do
    assert LoopBindingWorkflowDispatch.user_level_route?(%{
             routing_decision: %{execution_route: :user_level_plugin}
           })

    refute LoopBindingWorkflowDispatch.user_level_route?(%{
             routing_decision: %{execution_route: :ouroboros_workflow}
           })
  end

  test "interview_task? detects interview-shaped adapter routes only" do
    assert LoopBindingWorkflowDispatch.interview_task?(%{
             routing_decision: %{adapter_route: :interview}
           })

    assert LoopBindingWorkflowDispatch.interview_task?(%{
             routing_decision: %{adapter_route: :pm}
           })

    assert LoopBindingWorkflowDispatch.interview_task?(%{
             routing_decision: %{adapter_route: :workflow}
           })

    refute LoopBindingWorkflowDispatch.interview_task?(%{
             routing_decision: %{adapter_route: :run}
           })
  end

  test "adapter registry maps pm and workflow routes onto the interview invocation" do
    registry = LoopBindingWorkflowDispatch.adapter_registry()

    assert registry[{:ouroboros_workflow, :pm}] == Ourocode.Runtime.InterviewWorkflowInvocation
    assert registry[{:ouroboros, :pm}] == Ourocode.Runtime.InterviewWorkflowInvocation
    assert registry[:ouroboros_pm] == Ourocode.Runtime.InterviewWorkflowInvocation

    assert registry[{:ouroboros_workflow, :workflow}] ==
             Ourocode.Runtime.InterviewWorkflowInvocation

    assert registry[{:ouroboros, :workflow}] == Ourocode.Runtime.InterviewWorkflowInvocation
  end

  test "direct_task? detects non-MCP control routes" do
    assert LoopBindingWorkflowDispatch.direct_task?(%{
             routing_decision: %{adapter_route: :cancel}
           })

    assert LoopBindingWorkflowDispatch.direct_task?(%{
             routing_decision: %{adapter_route: :resume_session}
           })

    refute LoopBindingWorkflowDispatch.direct_task?(%{
             routing_decision: %{adapter_route: :run}
           })
  end

  test "parent_call_id is stable for string and integer ids" do
    assert LoopBindingWorkflowDispatch.parent_call_id(%{id: "abc"}) == "parent-abc"
    assert LoopBindingWorkflowDispatch.parent_call_id(%{id: 42}) == "parent-42"
  end

  test "input_event_model reads atom and string keyed active model" do
    model = %Model{
      id: :codex,
      label: "Codex",
      kind: :oauth,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk -> {:ok, ""} end
    }

    assert LoopBindingWorkflowDispatch.input_event_model(%{active_model: model}) == model
    assert LoopBindingWorkflowDispatch.input_event_model(%{"active_model" => model}) == model
    assert LoopBindingWorkflowDispatch.input_event_model(%{}) == nil
  end

  test "workflow_profile chooses an Ouroboros stage model instead of blindly reusing the active model" do
    active = model(:codex, "codex")

    task_request = %{
      routing_decision: %{
        execution_route: :ouroboros_workflow,
        adapter_route: :interview
      }
    }

    profile = LoopBindingWorkflowDispatch.workflow_profile(task_request, %{active_model: active})

    assert profile.label == "interview/precision"
    assert profile.model_id in [:claude_api, :codex, :gemini]
  end

  test "workflow_model keeps direct/user-level routes on the active model" do
    active = model(:codex, "codex")

    task_request = %{
      routing_decision: %{
        execution_route: :ouroboros_workflow,
        adapter_route: :cancel
      }
    }

    assert LoopBindingWorkflowDispatch.workflow_profile(task_request, %{active_model: active}) ==
             nil

    assert LoopBindingWorkflowDispatch.workflow_model(task_request, %{active_model: active}) ==
             active
  end

  test "workflow_context includes only available carry-forward values" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          interview: %{session_id: "session-1", ambiguity: 0.12},
          workflow: %{
            latest_seed_path: "/tmp/seed.md",
            latest_seed_content: "seed_id: seed-1\n",
            latest_seed_id: "seed-1",
            latest_job_id: "job-1",
            latest_auto_session_id: "auto-1",
            latest_workflow_session_id: "workflow-session-1",
            latest_execution_id: "exec-1",
            latest_lineage_id: "lin-1"
          }
        }
      end)

    assert LoopBindingWorkflowDispatch.workflow_context(agent) == %{
             latest_interview_session_id: "session-1",
             latest_interview_ambiguity: 0.12,
             latest_seed_path: "/tmp/seed.md",
             latest_seed_content: "seed_id: seed-1\n",
             latest_job_id: "job-1",
             latest_auto_session_id: "auto-1",
             latest_workflow_session_id: "workflow-session-1",
             latest_execution_id: "exec-1",
             latest_lineage_id: "lin-1"
           }

    Agent.stop(agent)
  end

  test "project_dir prefers runtime project_dir and falls back to cwd" do
    assert LoopBindingWorkflowDispatch.project_dir(%{project_dir: "/tmp/ourocode"}) ==
             "/tmp/ourocode"

    assert LoopBindingWorkflowDispatch.project_dir(%{}) == File.cwd!()
    assert LoopBindingWorkflowDispatch.project_dir(nil) == File.cwd!()
  end

  test "handle_prompt dispatches UserLevel plugin routes through the guarded command runner" do
    parent = self()
    {:ok, agent} = LoopBindings.start_link()

    task_request = %TaskRequest{
      id: "user-level-dispatch",
      source: :dashboard,
      task_input: "ooo superpowers list",
      submitted_at_ms: System.system_time(:millisecond),
      routing_decision: %{
        kind: :user_level_plugin,
        execution_route: :user_level_plugin,
        runtime_source: :ouroboros,
        transport: :auto,
        requires_command_syntax?: false,
        advanced_shortcut?: true,
        reason: :user_level_plugin_resolved,
        plugin_id: "superpowers"
      }
    }

    runtime = %{
      project_dir: File.cwd!(),
      user_level_capabilities: [superpowers_capability()],
      user_level_external_command_runner: fn command, args, opts ->
        send(parent, {:user_level_runner, command, args, opts})
        {:ok, %{status: 0, stdout: "listed", stderr: ""}}
      end
    }

    assert :ok ==
             LoopBindingWorkflowDispatch.handle_prompt(
               agent,
               runtime,
               task_request,
               %{},
               %{
                 enqueue_failure: fn _agent, _parent_call_id, reason ->
                   send(parent, {:failure, reason})
                   :ok
                 end,
                 run_interview_session: fn _agent, _opts -> :ok end,
                 production_parent_call: fn _agent, _runtime, _parent_call_id ->
                   fn _payload -> :ok end
                 end,
                 mcp_url: fn -> "http://127.0.0.1:4000/mcp" end
               }
             )

    assert_receive {:user_level_runner, "ouroboros", ["superpowers", "list"],
                    %{cwd: cwd, workflow_run_id: "workflow-run:parent-user-level-dispatch"}},
                   1_000

    assert cwd == File.cwd!()
    refute_receive {:failure, _reason}, 100

    LoopBindings.stop(agent)
  end

  test "handle_prompt uses the active model router for local PM questions when the MCP daemon is unavailable" do
    parent = self()
    previous_autostart = System.get_env("OUROCODE_MCP_AUTOSTART")
    System.put_env("OUROCODE_MCP_AUTOSTART", "0")

    on_exit(fn ->
      if previous_autostart,
        do: System.put_env("OUROCODE_MCP_AUTOSTART", previous_autostart),
        else: System.delete_env("OUROCODE_MCP_AUTOSTART")
    end)

    {:ok, agent} = LoopBindings.start_link()
    {:ok, model_calls} = Agent.start_link(fn -> 0 end)

    active_model = %Model{
      id: :codex,
      label: "Codex",
      kind: :oauth,
      status: :ready,
      run: fn prompt, _opts, on_chunk ->
        send(parent, {:model_prompt, prompt})

        response =
          Agent.get_and_update(model_calls, fn
            0 ->
              {
                """
                thinking through the product context
                ASK_USER Who should use this first?
                - Solo user | optimize for one person first
                - Small team | support shared coordination first
                """,
                1
              }

            count ->
              {
                """
                adapting to the previous answer
                ASK_USER What should prove the first version worked?
                - Task captured | user can add a task without friction
                - Task completed | user can finish a task and see progress
                """,
                count + 1
              }
          end)

        on_chunk.(response)
        {:ok, response}
      end
    }

    task_request = %TaskRequest{
      id: "pm-local-fallback",
      source: :dashboard,
      task_input: "ooo pm 간단한 할 일 앱 만들어줘",
      submitted_at_ms: System.system_time(:millisecond),
      routing_decision: %{
        kind: :ouroboros_workflow,
        execution_route: :ouroboros_workflow,
        runtime_source: :ouroboros,
        transport: :streamable_http,
        adapter_route: :pm,
        requires_command_syntax?: false,
        advanced_shortcut?: true,
        reason: :advanced_shortcut
      }
    }

    assert :ok ==
             LoopBindingWorkflowDispatch.handle_prompt(
               agent,
               %{project_dir: File.cwd!()},
               task_request,
               %{active_model: active_model},
               %{
                 enqueue_failure: fn _agent, _parent_call_id, reason ->
                   send(parent, {:failure, reason})
                   :ok
                 end,
                 run_interview_session: fn _agent, _opts ->
                   send(parent, :unexpected_live_interview)
                   :ok
                 end,
                 production_parent_call: fn _agent, _runtime, _parent_call_id ->
                   fn _payload -> {:error, :unexpected_parent_call} end
                 end,
                 mcp_url: fn -> "http://127.0.0.1:4000/mcp" end
               }
             )

    wait_for(fn ->
      snap = LoopBindings.pane_snapshot(agent)

      snap.wonder_tool &&
        snap.interview &&
        snap.interview.question == "Who should use this first?" &&
        Enum.map(snap.interview.question_options, & &1["label"]) == [
          "Solo user",
          "Small team"
        ] &&
        Enum.any?(Map.get(snap.interview, :reasoning, []), &String.contains?(&1, "thinking")) &&
        not String.contains?(
          snap.interview.question,
          "What outcome should this PM interview produce"
        )
    end)

    assert_receive {:model_prompt, prompt}, 1_000
    assert prompt =~ "간단한 할 일 앱 만들어줘"
    assert prompt =~ "ASK_USER <question for the human>"
    refute_receive :unexpected_live_interview, 100
    refute_receive {:failure, _reason}, 100

    snapshot = LoopBindings.pane_snapshot(agent)

    assert %{model_profile: %{model_id: :codex, llm_backend: "codex"}} =
             snapshot.runtime.workflow.runs["workflow-run:parent-pm-local-fallback"]

    assert {:ok, _selection} = LoopBindings.answer_wonder(agent, 1)

    wait_for(fn ->
      snap = LoopBindings.pane_snapshot(agent)

      snap.interview &&
        snap.interview.question == "What should prove the first version worked?" &&
        Enum.map(snap.interview.question_options, & &1["label"]) == [
          "Task captured",
          "Task completed"
        ] &&
        Map.get(snap.interview, :complete) == nil
    end)

    assert Agent.get(model_calls, & &1) == 2
    Agent.stop(model_calls)
    LoopBindings.stop(agent)
  end

  test "local fallback preserves Korean PM intent and extracts real ASK_USER questions" do
    parent = self()
    previous_autostart = System.get_env("OUROCODE_MCP_AUTOSTART")
    System.put_env("OUROCODE_MCP_AUTOSTART", "0")

    on_exit(fn ->
      restore_env("OUROCODE_MCP_AUTOSTART", previous_autostart)
    end)

    {:ok, agent} = LoopBindings.start_link()
    goal = korean_goal()

    active_model = %Model{
      id: :codex,
      label: "Codex",
      kind: :oauth,
      status: :ready,
      run: fn prompt, _opts, on_chunk ->
        send(parent, {:model_prompt, prompt})

        response = korean_ask_user_response()

        on_chunk.(response)
        {:ok, response}
      end
    }

    task_request = %TaskRequest{
      id: "pm-local-fallback-korean",
      source: :dashboard,
      task_input: "ooo pm " <> goal,
      submitted_at_ms: System.system_time(:millisecond),
      routing_decision: %{
        kind: :ouroboros_workflow,
        execution_route: :ouroboros_workflow,
        runtime_source: :ouroboros,
        transport: :streamable_http,
        adapter_route: :pm,
        requires_command_syntax?: false,
        advanced_shortcut?: true,
        reason: :advanced_shortcut
      }
    }

    assert :ok ==
             LoopBindingWorkflowDispatch.handle_prompt(
               agent,
               %{project_dir: File.cwd!()},
               task_request,
               %{active_model: active_model},
               %{
                 enqueue_failure: fn _agent, _parent_call_id, reason ->
                   send(parent, {:failure, reason})
                   :ok
                 end,
                 run_interview_session: fn _agent, _opts ->
                   send(parent, :unexpected_live_interview)
                   :ok
                 end,
                 production_parent_call: fn _agent, _runtime, _parent_call_id ->
                   fn _payload -> {:error, :unexpected_parent_call} end
                 end,
                 mcp_url: fn -> "http://127.0.0.1:4000/mcp" end
               }
             )

    wait_for(fn ->
      snap = LoopBindings.pane_snapshot(agent)

      snap.wonder_tool &&
        snap.interview &&
        snap.interview.question == korean_question() &&
        Enum.map(snap.interview.question_options, & &1["label"]) == korean_option_labels() &&
        Map.get(snap.interview, :complete) == nil
    end)

    assert_receive {:model_prompt, prompt}, 1_000
    assert prompt =~ goal
    assert prompt =~ "ASK_USER <question for the human>"
    refute_receive :unexpected_live_interview, 100
    refute_receive {:failure, _reason}, 100

    LoopBindings.stop(agent)
  end

  test "available MCP interview path is not masked by the local fallback" do
    parent = self()
    previous_url = System.get_env("OUROCODE_MCP_URL")
    previous_autostart = System.get_env("OUROCODE_MCP_AUTOSTART")

    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(socket)

    System.put_env("OUROCODE_MCP_URL", "http://127.0.0.1:#{port}/mcp")
    System.delete_env("OUROCODE_MCP_AUTOSTART")

    on_exit(fn ->
      :gen_tcp.close(socket)
      restore_env("OUROCODE_MCP_URL", previous_url)
      restore_env("OUROCODE_MCP_AUTOSTART", previous_autostart)
    end)

    {:ok, agent} = LoopBindings.start_link()

    active_model = %Model{
      id: :codex,
      label: "Codex",
      kind: :oauth,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk ->
        send(parent, :unexpected_local_model_run)
        {:ok, "ASK_USER This should not be used?"}
      end
    }

    task_request = %TaskRequest{
      id: "pm-live-mcp",
      source: :dashboard,
      task_input: "ooo pm 카드 뉴스를 만들어주는 나만의 SaaS를 만들고 싶어",
      submitted_at_ms: System.system_time(:millisecond),
      routing_decision: %{
        kind: :ouroboros_workflow,
        execution_route: :ouroboros_workflow,
        runtime_source: :ouroboros,
        transport: :streamable_http,
        adapter_route: :pm,
        requires_command_syntax?: false,
        advanced_shortcut?: true,
        reason: :advanced_shortcut
      }
    }

    assert :ok ==
             LoopBindingWorkflowDispatch.handle_prompt(
               agent,
               %{project_dir: File.cwd!()},
               task_request,
               %{active_model: active_model},
               %{
                 enqueue_failure: fn _agent, _parent_call_id, reason ->
                   send(parent, {:failure, reason})
                   :ok
                 end,
                 run_interview_session: fn _agent, opts ->
                   send(parent, {:live_interview, opts})
                   :ok
                 end,
                 production_parent_call: fn _agent, _runtime, parent_call_id ->
                   send(parent, {:parent_call_built, parent_call_id})
                   fn _payload -> {:ok, %{response: "Which question?"}} end
                 end,
                 mcp_url: fn -> "http://127.0.0.1:#{port}/mcp" end
               }
             )

    assert_receive {:parent_call_built, "parent-pm-live-mcp"}, 1_000

    assert_receive {:live_interview,
                    [
                      parent_call_id: "parent-pm-live-mcp",
                      initial_payload: %{"params" => %{"name" => "ouroboros_pm_interview"}},
                      parent_call_fun: parent_call_fun,
                      model: %Model{id: :codex},
                      workflow_run_id: "workflow-run:parent-pm-live-mcp",
                      project_dir: _
                    ]},
                   1_000

    assert is_function(parent_call_fun, 1)
    refute_receive :unexpected_local_model_run, 100
    refute_receive {:failure, _reason}, 100

    assert LoopBindings.pane_snapshot(agent).wonder_tool == nil

    LoopBindings.stop(agent)
  end

  test "local PM fallback asks whether to continue instead of ending at the round limit" do
    parent = self()
    previous_autostart = System.get_env("OUROCODE_MCP_AUTOSTART")
    System.put_env("OUROCODE_MCP_AUTOSTART", "0")

    on_exit(fn ->
      if previous_autostart,
        do: System.put_env("OUROCODE_MCP_AUTOSTART", previous_autostart),
        else: System.delete_env("OUROCODE_MCP_AUTOSTART")
    end)

    {:ok, agent} = LoopBindings.start_link()
    {:ok, model_calls} = Agent.start_link(fn -> 0 end)

    active_model = %Model{
      id: :codex,
      label: "Codex",
      kind: :oauth,
      status: :ready,
      run: fn _prompt, _opts, on_chunk ->
        call =
          Agent.get_and_update(model_calls, fn count ->
            next = count + 1
            {next, next}
          end)

        response = """
        ASK_USER Question #{call}?
        - Option #{call}A | first option
        - Option #{call}B | second option
        """

        on_chunk.(response)
        {:ok, response}
      end
    }

    task_request = %TaskRequest{
      id: "pm-local-fallback-continue",
      source: :dashboard,
      task_input: "ooo pm 카드 뉴스 SaaS",
      submitted_at_ms: System.system_time(:millisecond),
      routing_decision: %{
        kind: :ouroboros_workflow,
        execution_route: :ouroboros_workflow,
        runtime_source: :ouroboros,
        transport: :streamable_http,
        adapter_route: :pm,
        requires_command_syntax?: false,
        advanced_shortcut?: true,
        reason: :advanced_shortcut
      }
    }

    assert :ok ==
             LoopBindingWorkflowDispatch.handle_prompt(
               agent,
               %{project_dir: File.cwd!()},
               task_request,
               %{active_model: active_model},
               %{
                 enqueue_failure: fn _agent, _parent_call_id, reason ->
                   send(parent, {:failure, reason})
                   :ok
                 end,
                 run_interview_session: fn _agent, _opts ->
                   send(parent, :unexpected_live_interview)
                   :ok
                 end,
                 production_parent_call: fn _agent, _runtime, _parent_call_id ->
                   fn _payload -> {:error, :unexpected_parent_call} end
                 end,
                 mcp_url: fn -> "http://127.0.0.1:4000/mcp" end
               }
             )

    for round <- 1..6 do
      wait_for(fn ->
        snap = LoopBindings.pane_snapshot(agent)
        snap.interview && snap.interview.question == "Question #{round}?"
      end)

      assert {:ok, _selection} = LoopBindings.answer_wonder(agent, 1)
    end

    wait_for(fn ->
      snap = LoopBindings.pane_snapshot(agent)

      snap.interview &&
        snap.interview.question == "Do you want to keep interviewing or generate the seed now?" &&
        Enum.map(snap.interview.question_options, & &1["label"]) == [
          "Continue interview",
          "Generate seed now",
          "Stop for now"
        ] &&
        Map.get(snap.interview, :complete) == nil
    end)

    assert {:ok, _selection} = LoopBindings.answer_wonder(agent, 1)

    wait_for(fn ->
      snap = LoopBindings.pane_snapshot(agent)
      snap.interview && snap.interview.question == "Question 7?"
    end)

    refute_receive :unexpected_live_interview, 100
    refute_receive {:failure, _reason}, 100

    Agent.stop(model_calls)
    LoopBindings.stop(agent)
  end

  defp superpowers_capability do
    {:ok, capability} =
      Capability.new(%{
        plugin_id: "superpowers",
        source: :fixture,
        trust_scope: ["filesystem:read"],
        commands: [%{name: "list", risk_class: "read_only"}]
      })

    capability
  end

  defp model(id, label) do
    %Model{id: id, label: label, kind: :cli, status: :ready, run: fn _, _, _ -> :ok end}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp korean_goal do
    "\uce74\ub4dc \ub274\uc2a4\ub97c \ub9cc\ub4e4\uc5b4\uc8fc\ub294 " <>
      "\ub098\ub9cc\uc758 SaaS\ub97c \ub9cc\ub4e4\uace0 \uc2f6\uc5b4"
  end

  defp korean_question do
    "\uce74\ub4dc\ub274\uc2a4 SaaS\uc758 \uccab \uc0ac\uc6a9\uc790\ub294 " <>
      "\ub204\uad6c\uc778\uac00\uc694?"
  end

  defp korean_option_labels do
    [
      "1\uc778 \ucc3d\uc5c5\uc790",
      "\ub9c8\ucf00\ud305 \ud300",
      "\uad50\uc721 \uc6b4\uc601\uc790"
    ]
  end

  defp korean_ask_user_response do
    """
    ASK_USER #{korean_question()}
    - 1\uc778 \ucc3d\uc5c5\uc790 | \ud63c\uc790 \ucf58\ud150\uce20 \uc81c\uc791\uacfc \ubc30\ud3ec\ub97c \ucc98\ub9ac\ud569\ub2c8\ub2e4
    - \ub9c8\ucf00\ud305 \ud300 | \uc5ec\ub7ec \ucea0\ud398\uc778\uc758 \uce74\ub4dc\ub274\uc2a4\ub97c \ud568\uaed8 \uad00\ub9ac\ud569\ub2c8\ub2e4
    - \uad50\uc721 \uc6b4\uc601\uc790 | \uac15\uc758\ub098 \ud559\uc2b5 \uc790\ub8cc\ub97c \uce74\ub4dc\ub274\uc2a4\ub85c \ubc14\uafc9\ub2c8\ub2e4
    """
  end

  defp wait_for(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for(fun, deadline, nil)
  end

  defp wait_for(fun, deadline, last_value) do
    case fun.() do
      truthy when truthy not in [false, nil] ->
        truthy

      value ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(
            "condition was not met before timeout; last value: #{inspect(last_value || value)}"
          )
        else
          Process.sleep(20)
          wait_for(fun, deadline, value)
        end
    end
  end
end
