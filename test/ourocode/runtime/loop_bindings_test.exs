defmodule Ourocode.Runtime.LoopBindingsTest do
  @moduledoc """
  Proves the live seam the interactive loop depends on: routed runtime events
  are drained by a monotonic cursor, folded into live parent/child pane state,
  and exposed to the renderer via `pane_snapshot/1`.

  Network transport is intentionally not exercised here; it shares the same
  `route_event` -> pipeline -> poll seam this test drives deterministically.
  """

  use ExUnit.Case, async: false

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.Runtime.Application
  alias Ourocode.Runtime.LoopBindings

  setup do
    {:ok, runtime} =
      Application.bootstrap(%{
        project_dir: File.cwd!(),
        config: Ourocode.Config.defaults()
      })

    on_exit(fn -> Application.stop(runtime) end)
    %{runtime: runtime}
  end

  test "attach wires handlers and drains routed events into live panes", %{runtime: runtime} do
    assert {:ok, agent, options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    assert is_function(options[:on_prompt_input], 3)
    assert is_function(options[:poll_runtime_event], 1)
    assert is_function(options[:on_runtime_event], 2)

    poll = options[:poll_runtime_event]
    handle = options[:on_runtime_event]

    parent_call_id = "parent-loopbindings-1"

    parent_started =
      LifecycleEvent.new(:parent_call_started, %{
        event_seq: 1,
        transport: :streamable_http,
        parent_call_id: parent_call_id,
        runtime_source: "ouroboros",
        external_ids: %{session_id: "session-loopbindings-1"},
        occurred_at_ms: 1_000,
        request_id: "req-loopbindings",
        method: "tools/call"
      })

    # Transport relay ingests normalized events: panes fold immediately and
    # the loop poller still drains FIFO for bookkeeping.
    assert :ok == LoopBindings.enqueue(agent, parent_started)

    assert {:ok, drained} = poll.(%{})
    assert :none == poll.(%{})

    assert :ok == handle.(drained, %{})

    snapshot = LoopBindings.pane_snapshot(agent)

    assert %{runtime: %{parent_panes: parent, child_panes: child}} = snapshot
    assert is_map(child)

    assert [%{} | _] = parent.working
    assert parent.focused != nil

    rendered = Ourocode.Dashboard.ParentMcpPane.render(parent)
    assert [%{line: line} | _] = rendered.working
    assert line =~ "parent=#{parent_call_id}"
    assert line =~ "transport=streamable_http"
  end

  test "non-ouroboros prompt input is a no-op and never raises", %{runtime: runtime} do
    {:ok, _agent, options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    task_request = %Ourocode.TaskRequest{
      id: "plain-1",
      task_input: "just chatting",
      routing_decision: %{execution_route: :runtime, runtime_source: :auto, transport: :auto}
    }

    assert :ok == options[:on_prompt_input].(task_request, %{}, %{status: :healthy})
  end

  test "wonderTool checkpoint is detected live and answered back", %{runtime: runtime} do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    wonder_payload = %{
      "tool" => "wonderTool",
      "request_id" => "wt-1",
      "child_id" => "child-wt-1",
      "parent_call_id" => "parent-wt-1",
      "questions" => [
        %{
          "id" => "transport",
          "header" => "Transport",
          "question" => "Which MCP transport should the interview prioritize?",
          "options" => [
            %{"label" => "stdio", "description" => "local process pipe"},
            %{"label" => "streamable HTTP", "description" => "remote streaming"}
          ]
        }
      ]
    }

    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               payload: wonder_payload
             })

    snapshot = LoopBindings.pane_snapshot(agent)
    assert %{tool: :wonder_tool, question_count: 1} = snapshot.wonder_tool

    assert {:ok, decision} = LoopBindings.answer_wonder(agent, 2)
    assert decision.selected_label == "streamable HTTP"
    assert decision.question_id == "transport"

    # Overlay clears and the answer is folded back as a closing ack.
    assert LoopBindings.pane_snapshot(agent).wonder_tool == nil
    assert {:error, :no_active_wonder} = LoopBindings.answer_wonder(agent, 1)
  end

  test "wonderTool checkpoint can be cancelled without selecting an option", %{runtime: runtime} do
    {:ok, agent, options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    wonder_payload = %{
      "tool" => "wonderTool",
      "request_id" => "wt-cancel-1",
      "child_id" => "child-wt-cancel-1",
      "parent_call_id" => "parent-wt-cancel-1",
      "questions" => [
        %{
          "id" => "direction",
          "header" => "Direction",
          "question" => "Which direction should we take?",
          "options" => [
            %{"label" => "A", "description" => "first path"},
            %{"label" => "B", "description" => "second path"}
          ]
        }
      ]
    }

    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               payload: wonder_payload
             })

    assert %{tool: :wonder_tool} = LoopBindings.pane_snapshot(agent).wonder_tool

    assert {:ok, cancelled} = LoopBindings.cancel_wonder(agent, "decline")
    assert cancelled.cancelled == true
    assert cancelled.reason == "decline"
    assert cancelled.question_id == "direction"
    assert LoopBindings.pane_snapshot(agent).wonder_tool == nil

    poll = options[:poll_runtime_event]
    drained = drain_all(poll, [])

    assert Enum.any?(drained, fn event ->
             get_in(event, [:payload, :kind]) == :wonder_tool_cancelled and
               get_in(event, [:payload, :token]) == "declined: decline"
           end)

    assert {:error, :no_active_wonder} = LoopBindings.cancel_wonder(agent, "decline")
  end

  test "active wonderTool state survives unrelated runtime reload focus and pane events", %{
    runtime: runtime
  } do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               payload: %{
                 "tool" => "wonderTool",
                 "request_id" => "wt-preserve-1",
                 "child_id" => "child-wt-preserve-1",
                 "parent_call_id" => "parent-wt-preserve-1",
                 "questions" => [
                   %{
                     "id" => "direction",
                     "header" => "Direction",
                     "question" => "Which direction should we take?",
                     "options" => [
                       %{"label" => "A", "description" => "first path"},
                       %{"label" => "B", "description" => "second path"}
                     ]
                   }
                 ]
               }
             })

    before = LoopBindings.pane_snapshot(agent).wonder_tool
    assert before.request.request_id == "wt-preserve-1"

    for event <- [
          %{type: :plugin_config_reloaded, event_type: :plugin_config_reloaded, status: :loaded},
          %{
            type: :focus_changed,
            event_type: :focus_changed,
            focused_pane: "child-session:other"
          },
          LifecycleEvent.new(:parent_call_started, %{
            event_seq: 44,
            transport: :streamable_http,
            parent_call_id: "parent-other",
            runtime_source: "ouroboros",
            external_ids: %{},
            occurred_at_ms: 2_000,
            request_id: "req-other",
            method: "tools/call"
          })
        ] do
      assert :ok == LoopBindings.enqueue(agent, event)
      assert LoopBindings.pane_snapshot(agent).wonder_tool.request.request_id == "wt-preserve-1"
    end
  end

  test "absorbs an Ouroboros capability graph into the merged registry", %{runtime: runtime} do
    tools = [
      %{"name" => "ouroboros_interview", "description" => "Socratic interview"},
      %{"name" => "ouroboros_seed", "description" => "Generate a Seed"},
      %{"bogus" => "no name"}
    ]

    assert {:ok, result} = LoopBindings.ingest_capabilities(runtime, tools)
    assert %{accepted_entries: accepted} = result

    text = inspect(accepted)
    assert text =~ "ouroboros" and text =~ "interview"
    assert text =~ "seed"
    # Only the two named tools are absorbed; the nameless descriptor is dropped.
    assert length(accepted) == 2

    assert {:ok, :no_capabilities} = LoopBindings.ingest_capabilities(runtime, [])
  end

  test "interview reasoning is extracted from the wire response", %{runtime: runtime} do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    # The MCP interview wire-encodes `(ambiguity: X) <question>` + structured meta.
    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               parent_call_id: "parent-iv-1",
               child_id: "child-iv-1",
               payload: %{
                 "token" => "(ambiguity: 0.42) What MCP transports must the baseline support?",
                 "meta" => %{
                   "milestone" => "scope",
                   "seed_ready" => false,
                   "session_id" => "iv-sess-1"
                 }
               }
             })

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.interview.ambiguity == 0.42
    assert snap.interview.question =~ "What MCP transports"
    assert snap.interview.milestone == "scope"
    assert snap.interview.seed_ready == false
    assert snap.paused == false

    # Esc pauses without discarding the question; resume re-activates.
    assert :ok == LoopBindings.pause_wonder(agent)
    assert LoopBindings.pane_snapshot(agent).paused == true
    assert LoopBindings.pane_snapshot(agent).interview.question =~ "What MCP transports"
    assert :ok == LoopBindings.resume_wonder(agent)
    assert LoopBindings.pane_snapshot(agent).paused == false

    # Free-text answer is recorded and clears the pause.
    assert {:ok, "stdio, SSE, streamable HTTP"} =
             LoopBindings.answer_interview(agent, "stdio, SSE, streamable HTTP")

    assert LoopBindings.pane_snapshot(agent).interview.answered ==
             "stdio, SSE, streamable HTTP"

    assert {:error, :no_active_interview} ==
             LoopBindings.answer_interview(start_isolated_agent(), "x")
  end

  test "interview reasoning prefers structured MCP metadata", %{runtime: runtime} do
    {:ok, agent, _options} = LoopBindings.attach(%{status: :healthy, runtime: runtime})

    assert :ok ==
             LoopBindings.enqueue(agent, %{
               type: :child_event,
               source: :ouroboros,
               parent_call_id: "parent-iv-meta-1",
               child_id: "child-iv-meta-1",
               payload: %{
                 "token" => "Which MCP transport should the UI prioritize?",
                 "meta" => %{
                   "session_id" => "iv-meta-1",
                   "ambiguity_score" => 0.31,
                   "milestone" => "scope",
                   "seed_ready" => false,
                   "internal_reasoning" => [
                     "phase: answer",
                     "rounds: 1 answered / 2 total",
                     "next: ask user to answer pending question"
                   ],
                   "interview_reasoning" => %{
                     "phase" => "answer",
                     "pending_question" => true,
                     "next_action" => "ask user to answer pending question"
                   }
                 }
               }
             })

    snap = LoopBindings.pane_snapshot(agent)

    assert snap.interview.question =~ "Which MCP transport"
    assert snap.interview.ambiguity == 0.31
    assert snap.interview.milestone == "scope"
    assert snap.interview.seed_ready == false
    assert snap.interview.session_id == "iv-meta-1"

    assert snap.interview.mcp_reasoning == [
             "phase: answer",
             "rounds: 1 answered / 2 total",
             "next: ask user to answer pending question"
           ]

    assert snap.interview.mcp_reasoning_state["phase"] == "answer"
  end

  test "interview session loop: question → ANSWER → followup → seed-ready" do
    {:ok, agent} = LoopBindings.start_link()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.50) What language is this project?"}
              ],
              "meta" => %{"session_id" => "iv-1"}
            }
          }),
          parent_result(%{
            "result" => %{
              "content" => [%{"type" => "text", "text" => "(ambiguity: 0.10) 📍 Next: ooo seed"}]
            }
          })
        ]
      end)

    pcf = fn _payload ->
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    model = scripted_model(["ANSWER [from-code] Elixir 1.15, escript CLI (mix.exs)"])

    assert :ok ==
             LoopBindings.run_interview_session(agent,
               parent_call_id: "parent-iv-loop",
               initial_payload: %{
                 "params" => %{"name" => "ouroboros_interview", "arguments" => %{}}
               },
               parent_call_fun: pcf,
               model: model,
               project_dir: File.cwd!()
             )

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.interview.seed_ready == true
    assert snap.interview.complete == :seed_ready
    assert [_ | _] = snap.interview.router
    assert Enum.any?(snap.interview.router, &(&1 =~ "ANSWER [code]"))
  end

  test "interview session shows waiting state while MCP is generating a question" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    pcf = fn payload ->
      send(test_pid, {:pcf_waiting, payload})

      receive do
        :release_pcf ->
          {:ok,
           parent_result(%{
             "result" => %{
               "content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]
             }
           })}
      end
    end

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-waiting",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: scripted_model([]),
          project_dir: File.cwd!()
        )

        send(test_pid, :waiting_loop_done)
      end)

    assert_receive {:pcf_waiting, _initial}, 1_000

    snap = LoopBindings.pane_snapshot(agent)
    assert snap.interview.waiting == true
    assert snap.interview.status == "waiting for MCP interview question"
    assert snap.interview_session.status == "waiting for MCP interview question"

    send(loop, :release_pcf)
    assert_receive :waiting_loop_done, 1_000
  end

  test "interview session loop: ASK_USER routes to answer_interview handoff" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.80) Which payment provider?"}
              ],
              "meta" => %{"session_id" => "iv-ask-1"}
            }
          }),
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]}
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:followup, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    # The router never auto-answers a human-judgment question.
    model = scripted_model(["ASK_USER Which payment provider should we integrate?"])

    loop =
      spawn(fn ->
        LoopBindings.run_interview_session(agent,
          parent_call_id: "parent-iv-ask",
          initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
          parent_call_fun: pcf,
          model: model,
          project_dir: File.cwd!()
        )

        send(test_pid, :loop_done)
      end)

    # First parent call is the initial one.
    assert_receive {:followup, _initial}, 1_000

    # The loop is now blocked on the ASK_USER routing decision; the question
    # is pinned and a waiter is registered.
    wait_for(fn ->
      iv = LoopBindings.pane_snapshot(agent).interview
      iv && iv.question =~ "payment provider"
    end)

    iv = LoopBindings.pane_snapshot(agent).interview
    assert iv.waiting == false
    assert iv.status == "waiting for your answer"

    assert {:ok, "Stripe"} = LoopBindings.answer_interview(agent, "Stripe")

    # The user's answer is forwarded to MCP with the [from-user] prefix.
    assert_receive {:followup, followup}, 1_000
    assert followup["params"]["arguments"]["session_id"] == "iv-ask-1"
    assert followup["params"]["arguments"]["answer"] =~ "[from-user] Stripe"

    assert_receive :loop_done, 1_000
    assert Process.alive?(loop) == false

    assert LoopBindings.pane_snapshot(agent).interview.complete == :seed_ready
  end

  test "interview session loop: ASK_USER becomes a wonderTool, answer_wonder hands back" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.80) Which payment provider?"}
              ],
              "meta" => %{"session_id" => "iv-wt-1"}
            }
          }),
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]}
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:followup, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    model =
      scripted_model([
        "ASK_USER Which payment provider?\n- Stripe | USD-first subscription tooling\n- Toss | KRW-native for Korean MAU"
      ])

    spawn(fn ->
      LoopBindings.run_interview_session(agent,
        parent_call_id: "parent-wt",
        initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
        parent_call_fun: pcf,
        model: model,
        project_dir: File.cwd!()
      )

      send(test_pid, :loop_done)
    end)

    assert_receive {:followup, _initial}, 1_000

    # The ASK_USER was synthesized into a wonderTool checkpoint with the
    # model's options.
    wait_for(fn ->
      wt = LoopBindings.pane_snapshot(agent).wonder_tool
      wt && wt.question_count == 1
    end)

    snap = LoopBindings.pane_snapshot(agent)
    assert %{tool: :wonder_tool} = snap.wonder_tool
    assert snap.interview.question =~ "payment provider"

    # Picking option 1 hands the chosen label back to the blocked relay.
    assert {:ok, decision} = LoopBindings.answer_wonder(agent, 1)
    assert decision.selected_label == "Stripe"

    assert_receive {:followup, followup}, 1_000
    assert followup["params"]["arguments"]["session_id"] == "iv-wt-1"
    assert followup["params"]["arguments"]["answer"] =~ "[from-user] Stripe"

    assert_receive :loop_done, 1_000
    assert LoopBindings.pane_snapshot(agent).interview.complete == :seed_ready
  end

  test "answer_wonder: a multi-question checkpoint captures every question in order" do
    {:ok, agent} = LoopBindings.start_link()

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: "p-multi",
      runtime_source: "ouroboros",
      occurred_at_ms: 0,
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "p-multi-ask-1",
        "parent_call_id" => "p-multi",
        "questions" => [
          %{
            "id" => "transport",
            "header" => "Transport",
            "question" => "Which transport?",
            "options" => [
              %{"label" => "stdio", "description" => "local pipe"},
              %{"label" => "http", "description" => "remote stream"}
            ]
          },
          %{
            "id" => "scope",
            "header" => "Scope",
            "question" => "Which scope?",
            "options" => [
              %{"label" => "narrow", "description" => "one feature"},
              %{"label" => "broad", "description" => "whole module"}
            ]
          }
        ]
      }
    })

    assert LoopBindings.pane_snapshot(agent).wonder_tool.question_count == 2

    # One selection per question, in question order (1-based, like the TUI).
    assert {:ok, decision} = LoopBindings.answer_wonder(agent, [1, 2])
    assert decision.selected_label == "stdio; broad"
    assert length(decision.decisions) == 2
    assert Enum.map(decision.decisions, & &1.question_id) == ["transport", "scope"]
    assert Enum.map(decision.decisions, & &1.selected_label) == ["stdio", "broad"]

    # The checkpoint is closed and a combined ack reaches the child stream.
    assert is_nil(LoopBindings.pane_snapshot(agent).wonder_tool)
  end

  test "answer_wonder: a single-element list collapses to the legacy single answer" do
    {:ok, agent} = LoopBindings.start_link()

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: "p-one",
      runtime_source: "ouroboros",
      occurred_at_ms: 0,
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "p-one-ask-1",
        "parent_call_id" => "p-one",
        "questions" => [
          %{
            "id" => "transport",
            "header" => "Transport",
            "question" => "Which transport?",
            "options" => [
              %{"label" => "stdio", "description" => "local pipe"},
              %{"label" => "http", "description" => "remote stream"}
            ]
          }
        ]
      }
    })

    assert {:ok, decision} = LoopBindings.answer_wonder(agent, [2])
    assert decision.selected_label == "http"
    refute Map.has_key?(decision, :decisions)
  end

  test "answer_wonder: free text closes the checkpoint and records the answer" do
    {:ok, agent} = LoopBindings.start_link()

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: "p-free",
      runtime_source: "ouroboros",
      occurred_at_ms: 0,
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "p-free-ask-1",
        "parent_call_id" => "p-free",
        "questions" => [
          %{
            "id" => "ux_direction",
            "header" => "UX",
            "question" => "What should change?",
            "options" => [
              %{"label" => "Rendering", "description" => "question layout"},
              %{"label" => "Speed", "description" => "turn latency"}
            ]
          }
        ]
      }
    })

    assert %{tool: :wonder_tool} = LoopBindings.pane_snapshot(agent).wonder_tool

    assert {:ok, decision} =
             LoopBindings.answer_wonder(agent, %{"freeText" => "UX expert subagent consult"})

    assert decision.selected_label == "UX expert subagent consult"
    assert decision.free_text == "UX expert subagent consult"
    assert LoopBindings.pane_snapshot(agent).wonder_tool == nil
  end

  test "answer_wonder: free text can target a later multi-question id" do
    {:ok, agent} = LoopBindings.start_link()

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: "p-free-multi",
      runtime_source: "ouroboros",
      occurred_at_ms: 0,
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "p-free-multi-ask-1",
        "parent_call_id" => "p-free-multi",
        "questions" => [
          %{
            "id" => "transport",
            "header" => "Transport",
            "question" => "Which transport?",
            "options" => [
              %{"label" => "stdio", "description" => "local pipe"},
              %{"label" => "http", "description" => "remote stream"}
            ]
          },
          %{
            "id" => "scope",
            "header" => "Scope",
            "question" => "Which scope?",
            "options" => [
              %{"label" => "narrow", "description" => "one feature"},
              %{"label" => "broad", "description" => "whole module"}
            ]
          }
        ]
      }
    })

    assert {:ok, decision} =
             LoopBindings.answer_wonder(agent, %{
               "questionId" => "scope",
               "freeText" => "whole module with migration tests"
             })

    assert decision.question_id == "scope"
    assert decision.free_text == "whole module with migration tests"
    assert LoopBindings.pane_snapshot(agent).wonder_tool == nil
  end

  test "answer_wonder: multi-select single question preserves all selected options" do
    {:ok, agent} = LoopBindings.start_link()

    LoopBindings.enqueue(agent, %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: "p-multi-select",
      runtime_source: "ouroboros",
      occurred_at_ms: 0,
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "p-multi-select-ask-1",
        "parent_call_id" => "p-multi-select",
        "questions" => [
          %{
            "id" => "growth_axes",
            "header" => "Growth",
            "question" => "Which axes?",
            "multiSelect" => true,
            "options" => [
              %{"label" => "Users", "description" => "grow adoption"},
              %{"label" => "Features", "description" => "complete core"},
              %{"label" => "Business", "description" => "make sustainable"}
            ]
          }
        ]
      }
    })

    assert {:ok, decision} = LoopBindings.answer_wonder(agent, [1, 3])
    assert decision.multi_select? == true
    assert decision.selected_indices == [1, 3]
    assert decision.selected_label == "Users, Business"
  end

  test "the three-party dialogue log records MCP/MAIN turns with ambiguity + prefix" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "(ambiguity: 0.80) Which payment provider?"}
              ],
              "meta" => %{"session_id" => "iv-dlg-1"}
            }
          }),
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => "📍 Next: ooo seed"}]}
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:followup, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    # The answerer commits a code-derived fact (no user turn needed).
    model = scripted_model(["ANSWER [from-code] Stripe is already wired (lib/pay.ex)"])

    spawn(fn ->
      LoopBindings.run_interview_session(agent,
        parent_call_id: "parent-dlg",
        initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
        parent_call_fun: pcf,
        model: model,
        project_dir: File.cwd!()
      )

      send(test_pid, :loop_done)
    end)

    assert_receive :loop_done, 2_000

    dialogue =
      LoopBindings.pane_snapshot(agent).interview.dialogue
      |> Enum.reverse()
      |> Enum.map(&{&1.role, &1.text})

    assert dialogue == [
             {:mcp, "(ambiguity 0.80) Which payment provider?"},
             {:main, "[from-code] Stripe is already wired (lib/pay.ex)"},
             {:mcp, "interview complete (seed_ready) — next: ooo seed"}
           ]
  end

  test "interview session loop: user 'cancel' ends the session cleanly" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{
              "content" => [%{"type" => "text", "text" => "(ambiguity: 0.90) What is the goal?"}],
              "meta" => %{"session_id" => "iv-cancel"}
            }
          })
        ]
      end)

    pcf = fn _payload -> {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)} end
    model = scripted_model(["ASK_USER What is the goal of this work?"])

    spawn(fn ->
      LoopBindings.run_interview_session(agent,
        parent_call_id: "parent-iv-cancel",
        initial_payload: %{"params" => %{"name" => "ouroboros_interview", "arguments" => %{}}},
        parent_call_fun: pcf,
        model: model,
        project_dir: File.cwd!()
      )

      send(test_pid, :loop_done)
    end)

    wait_for(fn ->
      iv = LoopBindings.pane_snapshot(agent).interview
      iv && iv.question =~ "goal"
    end)

    assert {:ok, "cancel"} = LoopBindings.answer_interview(agent, "cancel")
    assert_receive :loop_done, 1_000
    assert LoopBindings.pane_snapshot(agent).interview.complete == :user_done
  end

  # Verbatim wire text captured from the live Ouroboros MCP server when its
  # clarification backend (gpt-5.5 via cliproxy) is down. FastMCP delivers
  # this server-side failure as `isError:false` + a "Question generation
  # failed: …" body — so it must be classified by text, not meta/isError.
  @real_502_text "Question generation failed: unexpected status 502 Bad Gateway: unknown provider for model gpt-5.5, url: https://cliproxy.zep.works/v1/responses (details: {'returncode': 1}). Session ID: interview_20260517_033303\n\nResume with: session_id=\"interview_20260517_033303\""

  test "interview loop: a server question-generation failure is surfaced, not routed as a question" do
    {:ok, agent} = LoopBindings.start_link()
    test_pid = self()

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => @real_502_text}]}
          })
        ]
      end)

    pcf = fn payload ->
      send(test_pid, {:pcf, payload})
      {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)}
    end

    # If the failure body were misrouted as a question this model would run.
    model =
      scripted_model(["ANSWER [from-code] this must never be sent — the loop must stop"])

    assert :ok ==
             LoopBindings.run_interview_session(agent,
               parent_call_id: "parent-502",
               initial_payload: %{
                 "params" => %{"name" => "ouroboros_interview", "arguments" => %{}}
               },
               parent_call_fun: pcf,
               model: model,
               project_dir: File.cwd!()
             )

    # Exactly one MCP call (the initial). No followup turn was sent.
    assert_receive {:pcf, _initial}
    refute_received {:pcf, _followup}

    iv = LoopBindings.pane_snapshot(agent).interview
    assert iv.status =~ "MCP question generator unavailable"
    assert iv.status =~ "502"
    # session id is recovered from the failure text so the run is resumable.
    assert iv.session_id == "interview_20260517_033303"
    assert iv.resumable == true
  end

  test "interview loop: real Ouroboros completion text ends the session" do
    {:ok, agent} = LoopBindings.start_link()

    completion =
      "Interview completed. Session ID: interview_x\n\n(ambiguity: 0.15) Ready for Seed generation.\nGenerate a Seed with: session_id=\"interview_x\""

    {:ok, calls} =
      Agent.start_link(fn ->
        [
          parent_result(%{
            "result" => %{"content" => [%{"type" => "text", "text" => completion}]}
          })
        ]
      end)

    pcf = fn _payload -> {:ok, Agent.get_and_update(calls, fn [h | t] -> {h, t} end)} end

    assert :ok ==
             LoopBindings.run_interview_session(agent,
               parent_call_id: "parent-done",
               initial_payload: %{
                 "params" => %{"name" => "ouroboros_interview", "arguments" => %{}}
               },
               parent_call_fun: pcf,
               model: scripted_model([]),
               project_dir: File.cwd!()
             )

    assert LoopBindings.pane_snapshot(agent).interview.complete == :seed_ready
  end

  defp parent_result(response) do
    %Ourocode.MCP.ParentCallResult{
      parent_call_id: "p",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      external_ids: %{},
      response: response
    }
  end

  defp scripted_model(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    %Ourocode.Model{
      id: :fake,
      label: "fake",
      kind: :cli,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk ->
        Agent.get_and_update(agent, fn
          [next | rest] -> {{:ok, next}, rest}
          [] -> {{:ok, "ASK_USER (script exhausted)"}, []}
        end)
      end
    }
  end

  defp wait_for(fun, attempts \\ 50) do
    cond do
      attempts <= 0 -> flunk("condition not met in time")
      fun.() -> :ok
      true -> Process.sleep(20) && wait_for(fun, attempts - 1)
    end
  end

  defp drain_all(poll, acc) do
    case poll.(%{}) do
      {:ok, event} -> drain_all(poll, [event | acc])
      :none -> Enum.reverse(acc)
    end
  end

  defp start_isolated_agent do
    {:ok, agent} = LoopBindings.start_link()
    agent
  end

  test "attach skips results without a runtime pipeline" do
    assert :skip == LoopBindings.attach(%{status: :healthy})
    assert :skip == LoopBindings.attach(%{status: :healthy, runtime: %{services: %{}}})
  end
end
