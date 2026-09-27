defmodule TradingSwarm.MixProject do
  use Mix.Project

  def project do
    [
      app: :trading_swarm,
      version: "0.1.0",
      elixir: "~> 1.14",
      description: "A concurrent, event-driven, multi-agent algorithmic trading engine in Elixir",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    base = [extra_applications: [:logger, :inets, :ssl]]
    
    if Mix.env() == :test do
      base
    else
      base ++ [mod: {TradingSwarm.Application, []}]
    end
  end

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end
end
