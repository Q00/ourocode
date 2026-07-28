defmodule Ourocode.MixProject do
  use Mix.Project

  def project do
    [
      app: :ourocode,
      version: "0.1.15-beta-1",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Ourocode.CLI],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.3"}
    ]
  end
end
