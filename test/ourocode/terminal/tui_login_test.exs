defmodule Ourocode.Terminal.TuiLoginTest do
  use ExUnit.Case, async: false

  alias Ourocode.Provider.{Anthropic, Codex}
  alias Ourocode.Terminal.{TuiLogin, TuiState}

  test "transient_poll_error? keeps polling on transport errors and retryable statuses" do
    assert TuiLogin.transient_poll_error?({:http_error, :timeout})
    assert TuiLogin.transient_poll_error?({:http_error, {:failed_connect, []}})
    assert TuiLogin.transient_poll_error?({:device_poll_failed, 408, %{}})
    assert TuiLogin.transient_poll_error?({:device_poll_failed, 429, %{}})
    assert TuiLogin.transient_poll_error?({:device_poll_failed, 500, %{}})
    assert TuiLogin.transient_poll_error?({:device_poll_failed, 503, %{}})
  end

  test "transient_poll_error? aborts on definitive 4xx poll failures" do
    refute TuiLogin.transient_poll_error?({:device_poll_failed, 400, %{}})
    refute TuiLogin.transient_poll_error?({:device_poll_failed, 410, %{}})
    refute TuiLogin.transient_poll_error?({:device_poll_failed, 422, %{}})
  end

  test "codex_entry_code strips separators for the 9-box browser device form" do
    assert TuiLogin.codex_entry_code("J46L-BMDBT") == "J46LBMDBT"
    assert TuiLogin.codex_entry_code("abcd efghi") == "ABCDEFGHI"
  end

  test "windows login opens device URL through the Windows URL handler" do
    assert TuiLogin.open_url_command(
             "https://auth.openai.com/codex/device",
             {:win32, :nt},
             fn _name -> nil end
           ) ==
             {"rundll32.exe",
              ["url.dll,FileProtocolHandler", "https://auth.openai.com/codex/device"]}
  end

  test "windows login copies device code through PowerShell clipboard" do
    assert TuiLogin.windows_clipboard_command("J46LBMDBT", {:win32, :nt}, fn
             "powershell.exe" -> "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
             _name -> nil
           end) ==
             {"C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe",
              ["-NoProfile", "-Command", "Set-Clipboard -Value $env:OUROCODE_CLIPBOARD_TEXT"],
              [{"OUROCODE_CLIPBOARD_TEXT", "J46LBMDBT"}]}
  end

  test "claude login arms a pending paste step with the Claude Code authorize URL" do
    with_tmp_home(fn ->
      state = TuiState.start_link()
      {:ok, output} = StringIO.open("")
      parent = self()

      redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end

      TuiLogin.start(:claude_api, %{}, output, state, 80, 24, redraw,
        open_url: fn url ->
          send(parent, {:opened, url})
          :ok
        end,
        copy_to_clipboard: fn text ->
          send(parent, {:copied, text})
          :ok
        end
      )

      pending = TuiState.pending_login(state)
      assert pending.provider == :claude_api
      assert is_binary(pending.verifier) and pending.verifier != ""
      assert pending.state == pending.verifier
      assert String.length(pending.state) == 43
      assert pending.redirect_uri == "https://platform.claude.com/oauth/code/callback"
      refute Map.has_key?(pending, :callback_pid)

      {_in, text} = StringIO.contents(output)
      assert text =~ "Opened browser and copied the sign-in link to clipboard."
      assert text =~ "Approve Claude access in the opened browser."
      refute text =~ "https://claude.com/cai/oauth/authorize"
      assert text =~ "paste the authorization code or final redirect URL"

      assert_receive {:opened, "https://claude.com/cai/oauth/authorize" <> _}
      assert_receive {:copied, "https://claude.com/cai/oauth/authorize" <> _}
    end)
  end

  test "claude login only prints the long URL when browser and clipboard helpers fail" do
    with_tmp_home(fn ->
      state = TuiState.start_link()
      {:ok, output} = StringIO.open("")
      redraw = fn _result, _output, _state, _buffer, _cols, _rows -> :ok end

      TuiLogin.start(:claude_api, %{}, output, state, 80, 24, redraw,
        open_url: fn _url -> {:error, :no_browser} end,
        copy_to_clipboard: fn _text -> {:error, :no_clipboard} end
      )

      {_in, text} = StringIO.contents(output)
      assert text =~ "Could not open the browser or copy the Claude sign-in link. Open this URL:"
      assert text =~ "https://claude.com/cai/oauth/authorize"
    end)
  end

  test "login reuses existing provider auth instead of starting a new browser flow" do
    with_tmp_home(fn ->
      live = System.system_time(:millisecond) + 600_000
      assert :ok = Anthropic.save(%{access: "claude-ac", refresh: "rf", expires: live})
      assert :ok = Codex.save(%{access: "codex-ac", refresh: "rf", expires: live})

      state = TuiState.start_link()
      {:ok, output} = StringIO.open("")
      parent = self()
      redraw = fn _result, _output, _state, _buffer, _cols, _rows -> send(parent, :redrawn) end
      fail = fn _value -> flunk("auth helper should not run when stored auth is usable") end

      TuiLogin.start(:claude_api, %{}, output, state, 80, 24, redraw,
        open_url: fail,
        copy_to_clipboard: fail
      )

      assert Agent.get(state, & &1.model_id) == :claude_api
      assert TuiState.pending_login(state) == nil
      assert_receive :redrawn

      TuiLogin.start(:codex, %{}, output, state, 80, 24, redraw,
        open_url: fail,
        copy_to_clipboard: fail
      )

      assert Agent.get(state, & &1.model_id) == :codex
      assert_receive :redrawn

      {_in, text} = StringIO.contents(output)
      assert text =~ "Already signed in. model: claude"
      assert text =~ "Already signed in. model: codex"
    end)
  end

  test "complete_paste is a no-op when no login is pending" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    assert TuiLogin.complete_paste("hello there", output, state) == :not_pending
  end

  defp with_tmp_home(fun) do
    tmp_home =
      Path.join(
        System.tmp_dir!(),
        "ourocode-tui-login-home-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_home)
    original = System.get_env("HOME")
    System.put_env("HOME", tmp_home)

    try do
      fun.()
    after
      if original, do: System.put_env("HOME", original), else: System.delete_env("HOME")
      File.rm_rf(tmp_home)
    end
  end
end
