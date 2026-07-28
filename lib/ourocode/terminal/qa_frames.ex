defmodule Ourocode.Terminal.QaFrames do
  @moduledoc false

  alias Ourocode.Terminal.{Tui, WorkspaceModel}

  @base_frame """
  +-- ourocode terminal region=header_status x=0 y=0 w=88 h=5
  | app=ourocode status=healthy runtime=ready session=demo
  | project=/Users/dev/Project/ourocode
  | cwd=/Users/dev/Project/ourocode
  +--
  +-- Parent/Child Sessions region=runtime_panes layout=terminal_split
  | [parent-region] x=0 y=0 w=80 h=8
  | parent empty
  | [child-region] x=0 y=9 w=80 h=12
  | child empty
  +--
  +-- Plugin Status (1) region=plugin_status x=0 y=18 w=80 h=4
  | status=ready visible=1
  | [BUILT-IN] Ouroboros workflows - Official plugin - loaded
  +--
  +-- State
  | surface=terminal focus=task_prompt layout=compact
  | runtime=ready stream=streaming journal=ready
  | queued=0 replayable?=true connections=ready
  | hooks=idle events=0
  +--
  """

  @spec all() :: [map()]
  def all do
    [
      frame("Start", 950, "", [], %{}),
      frame("Open guided work", 850, "ooo", [], %{}),
      frame("Type a goal", 750, "ooo pm design plugin onboarding", [], %{}),
      frame("Answer the interview", 1_450, "", ["you> ooo pm design plugin onboarding", "task: first picker ready"], %{
        interview_block: pm_picker_block(),
        wonder_focus: true
      }),
      frame("Continue safely", 1_200, "", ["you> ooo pm design plugin onboarding", "task: answer accepted"], %{
        interview_block: accepted_block()
      }),
      frame("Track active work", 1_250, "", [], %{workspace: agents_workspace()}),
      frame("Auto is approval-gated", 1_350, "", [], %{
        workspace: WorkspaceModel.workflow_start("ooo auto improve onboarding")
      })
    ]
  end

  @spec all_json() :: String.t()
  def all_json, do: all() |> Ourocode.Json.encode!() |> IO.iodata_to_binary()

  defp frame(title, duration_ms, prompt, activity, opts) do
    %{
      title: title,
      duration_ms: duration_ms,
      text:
        @base_frame
        |> Tui.frame_lines(activity, prompt, 100, 24, Map.put_new(opts, :auth, {"model: codex cli", :ok}))
        |> Enum.join("\n"),
      checks: checks_for(title)
    }
  end

  defp pm_picker_block do
    {"INTERVIEW",
     [
       "Round 1  ·  PM interview",
       "What outcome should this PM interview produce?",
       ">> [1] Define the target user - anchor the PM brief around the primary audience",
       "   [2] Define the activation outcome - focus on the proof moment",
       "   [3] Audit the existing flow - start from the current path"
     ], "Choose an option or type a custom answer"}
  end

  defp accepted_block do
    {"INTERVIEW",
     [
       {"Round accepted", :strong},
       {"Question  What outcome should this PM interview produce?", :warn},
       {"Answer    Define the target user", :strong},
       {"Next      answer sent; generating choices", :dim},
       :rule,
       {"■■⬝ building next answer choices (~6s) - no input needed; Esc pauses", :dim},
       {"No input needed; choices will appear automatically", :dim}
     ], "type your answer + Enter   Esc pause"}
  end

  defp agents_workspace do
    %{
      kind: "agents",
      title: "Agents",
      status: "running",
      selected: "agent:pm",
      records: [
        %{
          id: "agent:pm",
          title: "PM interview",
          state: "waiting",
          health: "live",
          fields: %{phase: "generating answer choices", progress: "answer accepted"}
        },
        %{
          id: "agent:verify",
          title: "Health checks",
          state: "ready",
          health: "ready",
          fields: %{phase: "ready", progress: "17 checks passed"}
        }
      ],
      detail: %{
        id: "agent:pm",
        title: "PM interview",
        state: "waiting",
        fields: %{
          phase: "generating answer choices",
          progress: "answer accepted",
          controls: "Esc pause, /cancel, /sessions"
        }
      },
      actions: [],
      shortcuts: ["Up/Dn rows", "Enter row action", "type to compose"],
      next: "Watch active work or type a new command."
    }
  end

  defp checks_for(title) do
    [
      %{label: "frame generated", status: "pass"},
      %{label: "terminal text present", status: "pass"},
      %{label: title |> String.downcase() |> String.replace(" ", "-"), status: "trace"}
    ]
  end
end

