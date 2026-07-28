defmodule Ourocode.Runtime.LoopBindingWorkflowDispatch do
  @moduledoc """
  Dispatches routed Ouroboros workflow prompts from the prompt loop.
  """

  alias Ourocode.Model
  alias Ourocode.Model.Catalog
  alias Ourocode.Model.Profile

  alias Ourocode.Runtime.{
    Dispatcher,
    InterviewProgress,
    LocalInterviewFallback,
    InterviewWorkflowInvocation,
    LoopBindingEventFlow,
    McpDaemonBinding,
    OuroborosDirectInvocation,
    OuroborosWorkflowInvocation,
    UserLevelPluginInvocation,
    WorkflowHarness,
    WorkflowRelay
  }

  alias Ourocode.Plugin.UserLevel.Registry, as: UserLevelRegistry

  @ouroboros_adapters %{
    {:ouroboros_workflow, :auto} => OuroborosWorkflowInvocation,
    {:ouroboros, :auto} => OuroborosWorkflowInvocation,
    :ouroboros_auto => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :interview} => InterviewWorkflowInvocation,
    {:ouroboros, :interview} => InterviewWorkflowInvocation,
    :ouroboros_interview => InterviewWorkflowInvocation,
    {:ouroboros_workflow, :pm} => InterviewWorkflowInvocation,
    {:ouroboros, :pm} => InterviewWorkflowInvocation,
    :ouroboros_pm => InterviewWorkflowInvocation,
    # Explicit `ooo workflow ...` requests have no dedicated workflow tool on
    # the live server, so they are safely absorbed into the interview flow
    # (default `ouroboros_interview` tool) instead of dispatch-failing.
    {:ouroboros_workflow, :workflow} => InterviewWorkflowInvocation,
    {:ouroboros, :workflow} => InterviewWorkflowInvocation,
    {:ouroboros_workflow, :seed} => OuroborosWorkflowInvocation,
    {:ouroboros, :seed} => OuroborosWorkflowInvocation,
    :ouroboros_seed => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :run} => OuroborosWorkflowInvocation,
    {:ouroboros, :run} => OuroborosWorkflowInvocation,
    :ouroboros_run => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :evolve} => OuroborosWorkflowInvocation,
    {:ouroboros, :evolve} => OuroborosWorkflowInvocation,
    :ouroboros_evolve => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :ralph} => OuroborosWorkflowInvocation,
    {:ouroboros, :ralph} => OuroborosWorkflowInvocation,
    :ouroboros_ralph => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :status} => OuroborosWorkflowInvocation,
    {:ouroboros, :status} => OuroborosWorkflowInvocation,
    :ouroboros_status => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :evaluate} => OuroborosWorkflowInvocation,
    {:ouroboros, :evaluate} => OuroborosWorkflowInvocation,
    :ouroboros_evaluate => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :qa} => OuroborosWorkflowInvocation,
    {:ouroboros, :qa} => OuroborosWorkflowInvocation,
    :ouroboros_qa => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :lateral} => OuroborosWorkflowInvocation,
    {:ouroboros, :lateral} => OuroborosWorkflowInvocation,
    :ouroboros_lateral => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :brownfield} => OuroborosWorkflowInvocation,
    {:ouroboros, :brownfield} => OuroborosWorkflowInvocation,
    :ouroboros_brownfield => OuroborosWorkflowInvocation,
    {:ouroboros_workflow, :cancel} => OuroborosDirectInvocation,
    {:ouroboros, :cancel} => OuroborosDirectInvocation,
    :ouroboros_cancel => OuroborosDirectInvocation,
    {:ouroboros_workflow, :resume_session} => OuroborosDirectInvocation,
    {:ouroboros, :resume_session} => OuroborosDirectInvocation,
    :ouroboros_resume_session => OuroborosDirectInvocation,
    {:ouroboros_workflow, :update} => OuroborosDirectInvocation,
    {:ouroboros, :update} => OuroborosDirectInvocation,
    :ouroboros_update => OuroborosDirectInvocation,
    {:ouroboros_workflow, :setup} => OuroborosDirectInvocation,
    {:ouroboros, :setup} => OuroborosDirectInvocation,
    :ouroboros_setup => OuroborosDirectInvocation,
    {:ouroboros_workflow, :publish} => OuroborosDirectInvocation,
    {:ouroboros, :publish} => OuroborosDirectInvocation,
    :ouroboros_publish => OuroborosDirectInvocation,
    {:ouroboros_workflow, :welcome} => OuroborosDirectInvocation,
    {:ouroboros, :welcome} => OuroborosDirectInvocation,
    :ouroboros_welcome => OuroborosDirectInvocation,
    {:ouroboros_workflow, :tutorial} => OuroborosDirectInvocation,
    {:ouroboros, :tutorial} => OuroborosDirectInvocation,
    :ouroboros_tutorial => OuroborosDirectInvocation,
    {:ouroboros_workflow, :help} => OuroborosDirectInvocation,
    {:ouroboros, :help} => OuroborosDirectInvocation,
    :ouroboros_help => OuroborosDirectInvocation,
    :user_level_plugin => UserLevelPluginInvocation
  }

  @type callbacks :: %{
          required(:enqueue_failure) => (pid(), String.t(), term() -> :ok),
          required(:run_interview_session) => (pid(), keyword() -> :ok),
          required(:production_parent_call) => (pid(), map(), String.t() -> function()),
          required(:mcp_url) => (-> String.t())
        }

  @doc false
  @spec adapter_registry() :: map()
  def adapter_registry, do: @ouroboros_adapters

  @spec handle_prompt(pid(), map(), map(), map(), callbacks()) :: :ok
  def handle_prompt(agent, runtime, task_request, input_event, callbacks)
      when is_pid(agent) and is_map(callbacks) do
    if dispatchable_route?(task_request) do
      parent_call_id = parent_call_id(task_request)
      workflow_run_id = "workflow-run:" <> parent_call_id
      profile = workflow_profile(task_request, input_event)

      LoopBindingEventFlow.enqueue(
        agent,
        WorkflowHarness.run_started_event(parent_call_id, task_request,
          run_id: workflow_run_id,
          model_profile: Profile.event_fields(profile)
        )
      )

      if interview_task?(task_request),
        do: InterviewProgress.mark_dispatching(agent, task_request, parent_call_id)

      spawn(fn ->
        dispatch_workflow(
          agent,
          runtime,
          task_request,
          input_event,
          parent_call_id,
          workflow_run_id,
          profile,
          callbacks
        )
      end)
    end

    :ok
  end

  @spec ouroboros_route?(map()) :: boolean()
  def ouroboros_route?(%{routing_decision: %{execution_route: :ouroboros_workflow}}), do: true
  def ouroboros_route?(_task_request), do: false

  @spec user_level_route?(map()) :: boolean()
  def user_level_route?(%{routing_decision: %{execution_route: :user_level_plugin}}), do: true
  def user_level_route?(_task_request), do: false

  # Routes that run the live interview session loop: `:interview` and `:pm`
  # (PM flavour calling `ouroboros_pm_interview`), plus `:workflow`, which is
  # absorbed into the interview flow because no dedicated workflow tool is
  # exposed by the server.
  @interview_adapter_routes [:interview, :pm, :workflow]
  @interview_tool_names ["ouroboros_interview", "ouroboros_pm_interview"]

  @spec interview_task?(map()) :: boolean()
  def interview_task?(%{routing_decision: %{adapter_route: adapter_route}})
      when adapter_route in @interview_adapter_routes,
      do: true

  def interview_task?(_task_request), do: false

  @spec direct_task?(map()) :: boolean()
  def direct_task?(%{routing_decision: %{adapter_route: adapter_route}}) do
    adapter_route in [
      :cancel,
      :resume_session,
      :update,
      :setup,
      :publish,
      :welcome,
      :tutorial,
      :help
    ]
  end

  def direct_task?(_task_request), do: false

  @spec parent_call_id(map()) :: String.t()
  def parent_call_id(task_request), do: "parent-" <> to_string(task_request.id)

  @spec workflow_context(pid()) :: map()
  def workflow_context(agent) when is_pid(agent) do
    Agent.get(agent, fn state ->
      interview = state.interview || %{}
      workflow = Map.get(state, :workflow, %{})

      %{
        latest_interview_session_id: Map.get(interview, :session_id),
        latest_interview_ambiguity: Map.get(interview, :ambiguity),
        latest_seed_path: Map.get(workflow, :latest_seed_path),
        latest_seed_content: Map.get(workflow, :latest_seed_content),
        latest_job_id: Map.get(workflow, :latest_job_id),
        latest_auto_session_id: Map.get(workflow, :latest_auto_session_id),
        latest_workflow_session_id: Map.get(workflow, :latest_workflow_session_id),
        latest_execution_id: Map.get(workflow, :latest_execution_id),
        latest_lineage_id: Map.get(workflow, :latest_lineage_id),
        latest_evaluation_artifact: Map.get(workflow, :latest_evaluation_artifact),
        latest_problem_context: Map.get(workflow, :latest_problem_context),
        latest_current_approach: Map.get(workflow, :latest_current_approach),
        latest_failed_attempts: Map.get(workflow, :latest_failed_attempts)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  @spec input_event_model(map()) :: Model.t() | nil
  def input_event_model(%{active_model: %Model{} = model}), do: model
  def input_event_model(%{"active_model" => %Model{} = model}), do: model
  def input_event_model(_event), do: nil

  @spec workflow_profile(map(), map()) :: Profile.t() | nil
  def workflow_profile(task_request, input_event) do
    if direct_task?(task_request) or user_level_route?(task_request) do
      nil
    else
      route =
        task_request
        |> Map.get(:routing_decision, %{})
        |> Map.get(:adapter_route)

      Profile.for_route(route, active_model: input_event_model(input_event))
    end
  end

  @spec workflow_model(map(), map()) :: Model.t()
  def workflow_model(task_request, input_event) do
    case workflow_profile(task_request, input_event) do
      %{model: %Model{} = model} -> model
      nil -> input_event_model(input_event) || Catalog.default()
    end
  end

  @spec project_dir(map() | term()) :: Path.t()
  def project_dir(runtime) when is_map(runtime),
    do: Map.get(runtime, :project_dir) || File.cwd!()

  def project_dir(_runtime), do: File.cwd!()

  defp dispatch_workflow(
         agent,
         runtime,
         task_request,
         input_event,
         parent_call_id,
         workflow_run_id,
         profile,
         callbacks
       ) do
    model =
      case profile do
        %{model: %Model{} = model} -> model
        _none -> input_event_model(input_event) || Catalog.default()
      end

    context =
      if direct_task?(task_request) or user_level_route?(task_request) do
        %{
          cwd: project_dir(runtime),
          workflow_run_id: workflow_run_id
        }
      else
        {:ok, mcp_url} = McpDaemonBinding.ensure(agent, model)

        if local_interview_fallback_enabled?(callbacks) and
             interview_task?(task_request) and
             LocalInterviewFallback.unavailable?(mcp_daemon(agent)) do
          LocalInterviewFallback.start(
            agent,
            task_request,
            parent_call_id,
            workflow_run_id,
            model,
            project_dir(runtime)
          )

          throw(:local_interview_fallback_started)
        end

        %{
          streamable_http_url: mcp_url,
          workflow_run_id: workflow_run_id,
          mcp_invoker:
            transport_invoker(agent, runtime, parent_call_id, workflow_run_id, model, callbacks)
        }
      end

    Dispatcher.dispatch(task_request,
      adapters: adapter_registry(),
      external_command_runner: external_command_runner(runtime),
      context:
        context
        |> Map.merge(%{
          request_id: "req-" <> to_string(task_request.id),
          parent_call_id: parent_call_id,
          workflow_run_id: workflow_run_id,
          cwd: project_dir(runtime),
          capabilities: user_level_capabilities(runtime),
          decision_journal: journal_path(runtime)
        })
        |> Map.merge(workflow_context(agent))
    )
    |> case do
      {:ok, _invocation} ->
        :ok

      {:error, reason} ->
        LoopBindingEventFlow.enqueue(agent, WorkflowHarness.failure_event(parent_call_id, reason))
        callbacks.enqueue_failure.(agent, parent_call_id, {:dispatch_failed, reason})
    end
  rescue
    exception ->
      LoopBindingEventFlow.enqueue(
        agent,
        WorkflowHarness.failure_event(
          "parent-" <> to_string(task_request.id),
          {:dispatch_exception, Exception.message(exception)}
        )
      )

      callbacks.enqueue_failure.(
        agent,
        "parent-" <> to_string(task_request.id),
        {:dispatch_exception, Exception.message(exception)}
      )
  catch
    :local_interview_fallback_started ->
      :ok
  end

  defp mcp_daemon(agent) do
    Agent.get(agent, &Map.get(&1, :mcp_daemon))
  end

  defp local_interview_fallback_enabled?(callbacks) do
    Map.get(callbacks, :local_interview_fallback?, true)
  end

  defp transport_invoker(agent, runtime, parent_call_id, workflow_run_id, model, callbacks) do
    fn payload, _transport_options ->
      start_relay(agent, runtime, parent_call_id, workflow_run_id, payload, model, callbacks)
      {:ok, %{parent_call_id: parent_call_id}}
    end
  end

  defp start_relay(agent, runtime, parent_call_id, workflow_run_id, payload, model, callbacks) do
    if interview_payload?(payload) do
      spawn(fn ->
        callbacks.run_interview_session.(
          agent,
          parent_call_id: parent_call_id,
          initial_payload: payload,
          parent_call_fun: callbacks.production_parent_call.(agent, runtime, parent_call_id),
          model: model,
          workflow_run_id: workflow_run_id,
          project_dir: project_dir(runtime)
        )
      end)
    else
      spawn(fn ->
        WorkflowRelay.run(
          agent,
          runtime,
          parent_call_id,
          payload,
          project_dir(runtime),
          callbacks.mcp_url.(),
          workflow_run_id: workflow_run_id
        )
      end)
    end
  end

  # Both interview tools must enter the interactive interview session loop;
  # anything else (start_*, status, ...) is a one-shot `WorkflowRelay` call.
  defp interview_payload?(payload) when is_map(payload) do
    get_in(payload, ["params", "name"]) in @interview_tool_names
  end

  defp interview_payload?(_payload), do: false

  defp dispatchable_route?(task_request) do
    ouroboros_route?(task_request) or user_level_route?(task_request)
  end

  defp user_level_capabilities(%{services: %{user_level_plugin_registry: pid}})
       when is_pid(pid) do
    pid
    |> UserLevelRegistry.list()
    |> Map.get(:capabilities, [])
  rescue
    _exception -> []
  end

  defp user_level_capabilities(%{user_level_capabilities: capabilities})
       when is_list(capabilities),
       do: capabilities

  defp user_level_capabilities(_runtime), do: []

  defp journal_path(%{journal: %{path: path}}) when is_binary(path), do: path
  defp journal_path(_runtime), do: nil

  defp external_command_runner(%{user_level_external_command_runner: runner})
       when is_function(runner, 3),
       do: runner

  defp external_command_runner(_runtime), do: &system_external_command_runner/3

  defp system_external_command_runner(command, args, opts) do
    system_opts =
      []
      |> maybe_put_system_opt(:cd, Map.get(opts, :cwd))
      |> maybe_put_system_opt(:env, Map.get(opts, :env))

    case System.cmd(command, args, system_opts) do
      {stdout, status} -> {:ok, %{status: status, stdout: stdout, stderr: ""}}
    end
  rescue
    exception in [ErlangError, File.Error, System.EnvError] ->
      {:error, {:external_command_failed, Exception.message(exception)}}
  end

  defp maybe_put_system_opt(opts, _key, nil), do: opts
  defp maybe_put_system_opt(opts, _key, ""), do: opts
  defp maybe_put_system_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
