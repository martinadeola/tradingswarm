defmodule TradingSwarm.Agents.BacktestOracle do
  @moduledoc """
  Backtesting engine that streams historical CSV data through the system.

  Enhanced reporting includes:
  - Sharpe Ratio per strategy
  - Maximum Drawdown per strategy
  - Total trades and win rate
  - Meta-agent leader transitions
  - Per-strategy comparison table
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  alias TradingSwarm.PerformanceTracker
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("[BacktestOracle] Initializing Backtest Engine...")
    Process.send_after(self(), :start_backtest, 2000)
    {:ok, %{lines: []}}
  end

  @impl true
  def handle_info(:start_backtest, state) do
    if File.exists?("data/historical.csv") do
      Logger.info("[BacktestOracle] Streaming data/historical.csv row by row...")

      Task.start(fn ->
        File.stream!("data/historical.csv")
        |> Stream.map(&String.trim/1)
        |> Stream.reject(fn line -> line == "" or String.starts_with?(line, "symbol") or String.starts_with?(line, "Datetime") end)
        |> Stream.with_index()
        |> Enum.each(fn {line, index} ->
          parts = String.split(line, ",")

          case parts do
            [sym, price_str, vol_str, time_str] ->
              {price, _} = Float.parse(price_str)
              {vol, _} = Integer.parse(vol_str)
              {:ok, time, _} = DateTime.from_iso8601(time_str)

              KnowledgeBase.assert(:market_data, %{
                symbol: sym,
                price: price,
                volume: vol,
                time: time
              })

              # Simulated Order Book with some structure
              bid_base = Enum.random(100..1000)
              ask_base = Enum.random(100..1000)
              KnowledgeBase.assert(:order_book, %{
                symbol: sym,
                bid_volume: bid_base,
                ask_volume: ask_base
              })

              # Publish macro event every 100 ticks (constant "Neutral" so backtest
              # results reflect pure technical signal quality, not fake sentiment)
              if rem(index, 100) == 0 do
                KnowledgeBase.assert(:macro_event, %{
                  sentiment: "Neutral",
                  score: 50,
                  source: "backtest",
                  impact: "Medium"
                })
              end

            _ ->
              Logger.warning("[BacktestOracle] Skipping malformed line: #{line}")
          end
        end)

        send(TradingSwarm.Agents.BacktestOracle, :backtest_complete)
      end)

      {:noreply, state}
    else
      Logger.error("[BacktestOracle] data/historical.csv not found! Run 'mix run generate_data.exs' first.")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:backtest_complete, state) do
    Logger.info("[BacktestOracle] 🏁 BACKTEST COMPLETE. All historical data processed. Calculating final results...")
    Process.send_after(self(), :print_results, 3000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:print_results, state) do
    IO.puts("\n")
    IO.puts("╔══════════════════════════════════════════════════════════════════╗")
    IO.puts("║                    BACKTEST RESULTS SUMMARY                     ║")
    IO.puts("╠══════════════════════════════════════════════════════════════════╣")

    strategy_names = %{
      1 => "Momentum",
      2 => "Reversion",
      3 => "VWAP",
      4 => "Pairs"
    }

    results =
      Enum.map(1..4, fn id ->
        port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: id}) |> List.first()
        positions = KnowledgeBase.get_by(:position, %{strategy_id: id})

        pos_value =
          Enum.reduce(positions, 0.0, fn p, acc ->
            acc + p.quantity * p.avg_price
          end)

        total = port.cash + pos_value
        pnl = total - 10_000.0
        pnl_pct = (pnl / 10_000.0) * 100

        metrics = PerformanceTracker.get_all_metrics(id)

        name = Map.get(strategy_names, id, "Strategy #{id}")

        IO.puts("║                                                                  ║")
        IO.puts("║  Strategy #{id}: #{String.pad_trailing(name, 10)}                                      ║")
        IO.puts("║  ─────────────────────────────────────────────                    ║")
        IO.puts("║  Cash:          $#{String.pad_trailing(Float.round(port.cash, 2) |> to_string(), 12)}                           ║")
        IO.puts("║  Positions:     $#{String.pad_trailing(Float.round(pos_value, 2) |> to_string(), 12)}                           ║")
        IO.puts("║  TRUE EQUITY:   $#{String.pad_trailing(Float.round(total, 2) |> to_string(), 12)}                           ║")
        IO.puts("║  P&L:           #{if pnl >= 0, do: "+", else: ""}$#{String.pad_trailing(Float.round(pnl, 2) |> to_string(), 11)} (#{String.pad_trailing(Float.round(pnl_pct, 2) |> to_string(), 6)}%)       ║")
        IO.puts("║  Sharpe Ratio:  #{String.pad_trailing(Float.round(metrics.sharpe, 3) |> to_string(), 12)}                           ║")
        IO.puts("║  Sortino Ratio: #{String.pad_trailing(Float.round(metrics.sortino, 3) |> to_string(), 12)}                           ║")
        IO.puts("║  Max Drawdown:  #{String.pad_trailing(Float.round(metrics.max_drawdown * 100, 2) |> to_string(), 11)}%                          ║")
        IO.puts("║  Open Positions: #{String.pad_trailing(length(positions) |> to_string(), 5)}                                    ║")

        %{id: id, name: name, equity: total, pnl: pnl, sharpe: metrics.sharpe, max_dd: metrics.max_drawdown}
      end)

    # Real Money (Strategy 0) results
    port_0 = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 0}) |> List.first()
    positions_0 = KnowledgeBase.get_by(:position, %{strategy_id: 0})
    pos_value_0 = Enum.reduce(positions_0, 0.0, fn p, acc -> acc + p.quantity * p.avg_price end)
    total_0 = port_0.cash + pos_value_0
    pnl_0 = total_0 - 10_000.0

    IO.puts("║                                                                  ║")
    IO.puts("╠══════════════════════════════════════════════════════════════════╣")
    IO.puts("║  💰 REAL MONEY (Strategy 0):                                    ║")
    IO.puts("║  TRUE EQUITY:   $#{String.pad_trailing(Float.round(total_0, 2) |> to_string(), 12)}                           ║")
    IO.puts("║  P&L:           #{if pnl_0 >= 0, do: "+", else: ""}$#{String.pad_trailing(Float.round(pnl_0, 2) |> to_string(), 12)}                          ║")

    # Meta-Agent leader info
    meta = KnowledgeBase.get_by(:meta_strategy) |> List.first()
    if meta do
      leader_name = Map.get(strategy_names, meta.leader_id, "Strategy #{meta.leader_id}")
      IO.puts("║  Current Leader: Strategy #{meta.leader_id} (#{leader_name})                          ║")
    end

    # Best strategy
    best = Enum.max_by(results, fn r -> r.sharpe end)
    IO.puts("║                                                                  ║")
    IO.puts("║  🏆 Best Risk-Adjusted: Strategy #{best.id} (#{best.name})                      ║")
    IO.puts("║     Sharpe: #{Float.round(best.sharpe, 3)}  |  Max DD: #{Float.round(best.max_dd * 100, 2)}%                       ║")

    IO.puts("╚══════════════════════════════════════════════════════════════════╝")

    # Halt the system cleanly
    System.halt(0)

    {:noreply, state}
  end
end
