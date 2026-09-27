defmodule TradingSwarm.PerformanceTracker do
  @moduledoc """
  Tracks per-strategy equity time series and computes risk-adjusted performance metrics.

  Periodically snapshots equity for each strategy and provides:
  - Sharpe Ratio (annualized)
  - Sortino Ratio (downside-only risk)
  - Maximum Drawdown
  - Win Rate
  - Profit Factor
  - Total Trades count
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase

  @snapshot_interval 5000  # 5 seconds between snapshots

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Get the Sharpe ratio for a strategy. Returns 0.0 if insufficient data."
  def get_sharpe(strategy_id) do
    GenServer.call(__MODULE__, {:get_sharpe, strategy_id})
  end

  @doc "Get the Sortino ratio for a strategy."
  def get_sortino(strategy_id) do
    GenServer.call(__MODULE__, {:get_sortino, strategy_id})
  end

  @doc "Get maximum drawdown for a strategy (as a negative percentage)."
  def get_max_drawdown(strategy_id) do
    GenServer.call(__MODULE__, {:get_max_drawdown, strategy_id})
  end

  @doc "Get all metrics for a strategy."
  def get_all_metrics(strategy_id) do
    GenServer.call(__MODULE__, {:get_all, strategy_id})
  end

  @doc "Get the number of equity snapshots for a strategy."
  def snapshot_count(strategy_id) do
    GenServer.call(__MODULE__, {:snapshot_count, strategy_id})
  end

  # --- Server ---

  @impl true
  def init(_) do
    Process.send_after(self(), :snapshot, @snapshot_interval)

    # Also subscribe to market_data for event-driven snapshots during backtests
    # (backtests blast data faster than the 5s timer can capture)
    KnowledgeBase.subscribe(:market_data)
    KnowledgeBase.subscribe(:order_receipt)

    # State: %{strategy_id => %{equity_history: [float]}}
    {:ok, %{strategies: %{}, tick_count: 0, latest_prices: %{}}}
  end

  @impl true
  def handle_call({:get_sharpe, id}, _from, state) do
    {:reply, calculate_sharpe(state, id), state}
  end

  @impl true
  def handle_call({:get_sortino, id}, _from, state) do
    {:reply, calculate_sortino(state, id), state}
  end

  @impl true
  def handle_call({:get_max_drawdown, id}, _from, state) do
    {:reply, calculate_max_drawdown(state, id), state}
  end

  @impl true
  def handle_call({:snapshot_count, id}, _from, state) do
    count = case Map.get(state.strategies, id) do
      nil -> 0
      tracker -> length(tracker.equity_history)
    end
    {:reply, count, state}
  end

  @impl true
  def handle_call({:get_all, id}, _from, state) do
    metrics = %{
      sharpe: calculate_sharpe(state, id),
      sortino: calculate_sortino(state, id),
      max_drawdown: calculate_max_drawdown(state, id),
      current_equity: get_latest_equity(state, id),
      snapshots: case Map.get(state.strategies, id) do
        nil -> 0
        t -> length(t.equity_history)
      end
    }
    {:reply, metrics, state}
  end

  @impl true
  def handle_info(:snapshot, state) do
    new_strategies =
      Enum.reduce(0..4, state.strategies, fn strategy_id, acc ->
        equity = calculate_equity(strategy_id, state)

        if equity > 0 do
          tracker = Map.get(acc, strategy_id, %{equity_history: []})

          last_equity = case tracker.equity_history do
            [last | _] -> last
            [] -> 10000.0
          end

          # Filter out anomalous spikes (>5% in one tick) caused by ETS race conditions between Accountant and PerformanceTracker
          if abs(equity - last_equity) / last_equity < 0.05 do
            # Keep last 500 snapshots (rolling window)
            new_history = [equity | Enum.take(tracker.equity_history, 499)]
            Map.put(acc, strategy_id, %{tracker | equity_history: new_history})
          else
            acc
          end
        else
          acc
        end
      end)

    Process.send_after(self(), :snapshot, @snapshot_interval)
    {:noreply, %{state | strategies: new_strategies}}
  end

  @impl true
  def handle_info({:fact_asserted, :market_data, md}, state) do
    # Track latest price for accurate equity calculation
    new_prices = Map.put(state.latest_prices, md.symbol, md.price)
    
    # Snapshot every 10th tick for backtest performance tracking
    tick = state.tick_count + 1

    if rem(tick, 10) == 0 do
      send(self(), :snapshot)
    end

    {:noreply, %{state | tick_count: tick, latest_prices: new_prices}}
  end

  @impl true
  def handle_info({:fact_asserted, :order_receipt, _rec}, state) do
    # Always snapshot on trade completion for accurate P&L tracking
    send(self(), :snapshot)
    {:noreply, state}
  end

  # --- Calculations ---

  defp calculate_sharpe(state, id) do
    case Map.get(state.strategies, id) do
      nil -> 0.0
      %{equity_history: history} when length(history) < 10 -> 0.0
      %{equity_history: history} ->
        returns = compute_returns(history)
        mean_return = Enum.sum(returns) / length(returns)
        std = standard_deviation(returns)

        if std > 0.000001 do
          # Annualize: assuming ~252 trading days, ~6.5 hours/day, snapshots every 5s
          # But for simplicity, just scale by sqrt(N) where N = snapshots per day
          (mean_return / std) * :math.sqrt(252)
        else
          0.0
        end
    end
  end

  defp calculate_sortino(state, id) do
    case Map.get(state.strategies, id) do
      nil -> 0.0
      %{equity_history: history} when length(history) < 10 -> 0.0
      %{equity_history: history} ->
        returns = compute_returns(history)
        mean_return = Enum.sum(returns) / length(returns)

        # Downside deviation: only negative returns
        downside_returns = Enum.filter(returns, &(&1 < 0))

        downside_std = if length(downside_returns) > 1 do
          standard_deviation(downside_returns)
        else
          0.0001
        end

        if downside_std > 0.000001 do
          (mean_return / downside_std) * :math.sqrt(252)
        else
          0.0
        end
    end
  end

  defp calculate_max_drawdown(state, id) do
    case Map.get(state.strategies, id) do
      nil -> 0.0
      %{equity_history: history} when length(history) < 2 -> 0.0
      %{equity_history: history} ->
        # History is newest-first, so reverse for chronological order
        chronological = Enum.reverse(history)

        {_peak, max_dd} =
          Enum.reduce(chronological, {0.0, 0.0}, fn equity, {peak, max_dd} ->
            new_peak = max(peak, equity)
            dd = if new_peak > 0, do: (equity - new_peak) / new_peak, else: 0.0
            {new_peak, min(max_dd, dd)}
          end)

        max_dd
    end
  end

  defp get_latest_equity(state, id) do
    case Map.get(state.strategies, id) do
      nil -> 0.0
      %{equity_history: [latest | _]} -> latest
      _ -> 0.0
    end
  end

  defp compute_returns(history) when length(history) < 2, do: []
  defp compute_returns(history) do
    # History is newest-first: [newest, ..., oldest]
    history
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [current, previous] ->
      if previous > 0, do: (current - previous) / previous, else: 0.0
    end)
  end

  defp standard_deviation(values) when length(values) < 2, do: 0.0
  defp standard_deviation(values) do
    n = length(values)
    mean = Enum.sum(values) / n
    variance = Enum.reduce(values, 0.0, fn v, acc -> acc + :math.pow(v - mean, 2) end) / n
    :math.sqrt(variance)
  end

  defp calculate_equity(strategy_id, state) do
    port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: strategy_id}) |> List.first()

    if port != nil do
      positions = KnowledgeBase.get_by(:position, %{strategy_id: strategy_id})

      pos_value =
        Enum.reduce(positions, 0.0, fn pos, acc ->
          price = Map.get(state.latest_prices, pos.symbol, pos.avg_price)
          acc + pos.quantity * price
        end)

      port.cash + pos_value
    else
      0.0
    end
  end
end
