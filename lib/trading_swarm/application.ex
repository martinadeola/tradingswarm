defmodule TradingSwarm.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    universe = Application.get_env(:trading_swarm, :universe, ["AAPL", "MSFT", "GOOG"])

    children = [
      {Registry, keys: :duplicate, name: TradingSwarm.PubSub},
      TradingSwarm.KnowledgeBase,

      # Data Oracle
      if System.get_env("MODE") == "backtest" do
        TradingSwarm.Agents.BacktestOracle
      else
        TradingSwarm.Agents.Oracle
      end,

      # Macro Sentiment (live mode only — backtest uses constant "Neutral")
      unless System.get_env("MODE") == "backtest" do
        TradingSwarm.MacroSentiment
      end,

      # Sub-strategy Quants (4 strategies)
      {TradingSwarm.Agents.QuantMomentum, %{id: 1, std_dev: 2.0, volume_threshold: 5000}},
      {TradingSwarm.Agents.QuantReversion, %{id: 2, std_dev: 1.5, volume_threshold: 5000}},
      {TradingSwarm.Agents.QuantVWAP, %{id: 3}},
      {TradingSwarm.Agents.QuantPairs, %{id: 4}},

      # Strategy-specific Risk Managers (0 = real money, 1-4 = virtual strategies)
      Supervisor.child_spec({TradingSwarm.Agents.RiskManager, %{strategy_id: 1}}, id: :risk_manager_1),
      Supervisor.child_spec({TradingSwarm.Agents.RiskManager, %{strategy_id: 2}}, id: :risk_manager_2),
      Supervisor.child_spec({TradingSwarm.Agents.RiskManager, %{strategy_id: 3}}, id: :risk_manager_3),
      Supervisor.child_spec({TradingSwarm.Agents.RiskManager, %{strategy_id: 4}}, id: :risk_manager_4),
      Supervisor.child_spec({TradingSwarm.Agents.RiskManager, %{strategy_id: 0}}, id: :risk_manager_0),

      # Execution & Accounting
      TradingSwarm.Agents.Broker,
      {TradingSwarm.Agents.ExchangeMatcher, %{}},
      TradingSwarm.Agents.Accountant,

      # Performance Tracking & Risk Protection
      TradingSwarm.PerformanceTracker,
      TradingSwarm.Agents.CircuitBreaker,

      # The Meta Agent
      TradingSwarm.Agents.MetaAgent,

      # Infrastructure
      TradingSwarm.Agents.GarbageCollector
    ]
    |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: TradingSwarm.Supervisor]

    # Initialize some starting facts before full supervisor boot completes
    result = Supervisor.start_link(children, opts)

    if match?({:ok, _pid}, result) do
      # Only initialize portfolios if they don't already exist (DETS may have restored them)
      unless TradingSwarm.KnowledgeBase.has_facts?(:portfolio_state) do
        Enum.each(0..4, fn id ->
          TradingSwarm.KnowledgeBase.assert(:portfolio_state, %{cash: 10000.0, strategy_id: id})
        end)
      end

      unless TradingSwarm.KnowledgeBase.has_facts?(:meta_strategy) do
        TradingSwarm.KnowledgeBase.assert(:meta_strategy, %{leader_id: 1})
      end

      # Always refresh universe tickers from config (these are ephemeral)
      Enum.each(universe, fn sym ->
        TradingSwarm.KnowledgeBase.assert(:universe_ticker, %{symbol: sym})
      end)
    end

    result
  end
end
