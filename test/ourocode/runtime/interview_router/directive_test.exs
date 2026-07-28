defmodule Ourocode.Runtime.InterviewRouter.DirectiveTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewRouter.Directive

  test "parses tool directives" do
    assert Directive.parse("TOOL READ mix.exs") == {:tool, :read, "mix.exs"}
    assert Directive.parse("TOOL GLOB lib/**/*.ex") == {:tool, :glob, "lib/**/*.ex"}

    assert Directive.parse("TOOL GREP defmodule lib/**/*.ex") ==
             {:tool, :grep, "defmodule lib/**/*.ex"}
  end

  test "parses answer directives with multiline payload" do
    assert Directive.parse("""
           ANSWER [from-code] The app is Elixir.
           It uses Mix.
           """) == {:answer, "[from-code] The app is Elixir.\nIt uses Mix."}
  end

  test "parses ask-user directives with suggested options" do
    assert Directive.parse("""
           ASK_USER Which scope should we take?
           - Small | Touch one module
           - Broad | Include related runtime paths
           """) ==
             {:ask_user, "Which scope should we take?",
              [
                %{label: "Small", description: "Touch one module"},
                %{label: "Broad", description: "Include related runtime paths"}
              ]}
  end

  test "parses ask-user directives with ASCII pipe options" do
    assert Directive.parse("""
           ASK_USER Which proof should gate this change?
           - Focused tests | Parser and fallback regressions only
           - Full suite | Broader confidence after the focused checks
           """) ==
             {:ask_user, "Which proof should gate this change?",
              [
                %{label: "Focused tests", description: "Parser and fallback regressions only"},
                %{label: "Full suite", description: "Broader confidence after the focused checks"}
              ]}
  end

  test "parses ask-user directives with fullwidth pipe options" do
    assert Directive.parse("""
           ASK_USER 어떤 옵션 구분자를 허용해야 하나요?
           - ASCII ｜ 기존 모델 출력과 호환됩니다
           - Fullwidth ｜ 한국어 입력기 출력과 호환됩니다
           """) ==
             {:ask_user, "어떤 옵션 구분자를 허용해야 하나요?",
              [
                %{label: "ASCII", description: "기존 모델 출력과 호환됩니다"},
                %{label: "Fullwidth", description: "한국어 입력기 출력과 호환됩니다"}
              ]}
  end

  test "parses Korean ask-user option labels with spaces" do
    assert Directive.parse("""
           ASK_USER \uce74\ub4dc\ub274\uc2a4 SaaS\uc758 \uccab \uc0ac\uc6a9\uc790\ub294 \ub204\uad6c\uc778\uac00\uc694?
           - 1\uc778 \ucc3d\uc5c5\uc790 | \ud63c\uc790 \ucf58\ud150\uce20 \uc81c\uc791\uacfc \ubc30\ud3ec\ub97c \ucc98\ub9ac\ud569\ub2c8\ub2e4
           - \ub9c8\ucf00\ud305 \ud300 | \uc5ec\ub7ec \ucea0\ud398\uc778\uc758 \uce74\ub4dc\ub274\uc2a4\ub97c \ud568\uaed8 \uad00\ub9ac\ud569\ub2c8\ub2e4
           - \uad50\uc721 \uc6b4\uc601\uc790 | \uac15\uc758\ub098 \ud559\uc2b5 \uc790\ub8cc\ub97c \uce74\ub4dc\ub274\uc2a4\ub85c \ubc14\uafc9\ub2c8\ub2e4
           """) ==
             {:ask_user,
              "\uce74\ub4dc\ub274\uc2a4 SaaS\uc758 \uccab \uc0ac\uc6a9\uc790\ub294 \ub204\uad6c\uc778\uac00\uc694?",
              [
                %{
                  label: "1\uc778 \ucc3d\uc5c5\uc790",
                  description:
                    "\ud63c\uc790 \ucf58\ud150\uce20 \uc81c\uc791\uacfc \ubc30\ud3ec\ub97c \ucc98\ub9ac\ud569\ub2c8\ub2e4"
                },
                %{
                  label: "\ub9c8\ucf00\ud305 \ud300",
                  description:
                    "\uc5ec\ub7ec \ucea0\ud398\uc778\uc758 \uce74\ub4dc\ub274\uc2a4\ub97c \ud568\uaed8 \uad00\ub9ac\ud569\ub2c8\ub2e4"
                },
                %{
                  label: "\uad50\uc721 \uc6b4\uc601\uc790",
                  description:
                    "\uac15\uc758\ub098 \ud559\uc2b5 \uc790\ub8cc\ub97c \uce74\ub4dc\ub274\uc2a4\ub85c \ubc14\uafc9\ub2c8\ub2e4"
                }
              ]}
  end

  test "expands inline ask-user options" do
    assert Directive.parse(
             "ASK_USER Pick scope - Small | One module - Broad | Related runtime paths"
           ) ==
             {:ask_user, "Pick scope",
              [
                %{label: "Small", description: "One module"},
                %{label: "Broad", description: "Related runtime paths"}
              ]}
  end

  test "expands inline ask-user options with fullwidth pipes" do
    assert Directive.parse(
             "ASK_USER Pick scope - Small ｜ One module - Broad ｜ Related runtime paths"
           ) ==
             {:ask_user, "Pick scope",
              [
                %{label: "Small", description: "One module"},
                %{label: "Broad", description: "Related runtime paths"}
              ]}
  end

  test "finds first directive after echoed prompt and drops cli footer" do
    wrapped = """
    runner banner
    ## Your reply
    ignored prompt copy
    ANSWER [from-code] Existing architecture is modular.
    tokens used
    123
    """

    assert Directive.parse(wrapped) ==
             {:answer, "[from-code] Existing architecture is modular."}
  end

  test "returns unparseable for prose" do
    assert Directive.parse("I think we should ask the user") == :unparseable
    assert Directive.parse(nil) == :unparseable
  end
end
