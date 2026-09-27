defmodule TradingSwarm.Agents.CircuitBreaker do
  @moduledoc """
  Protects capital by halting new entries when drawdown limits are breached.

  Two circuit breakers per strategy:
  - Daily: Trips at -3% drawdown from day-start equity. Resets each trading day.
  - Total: Trips at -10% drawdown from peak equity. Requires manual reset.

  Exit/cover trades are ALWAYS allowed, even when breakers are tripped.
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  require Logger

  @daily_drawdown_limit -0.03   # -3% from day-start equity
  @total_drawdown_limit -0.10   # -10% from peak equity

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Check if a strategy is allowed to open new positions."
  def can_open_position?(strategy_id) do
    GenServer.call(__MODULE__, {:can_open?, strategy_id})
  end

  @doc "Manually reset circuit breakers for a strategy (after human review)."
  def reset(strategy_id) do
    GenServer.call(__MODULE__, {:reset, strategy_id})
  end

  @doc "Get current circuit breaker status for all strategies."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- Server ---

  @impl true
  def init(_) do
    KnowledgeBase.subscribe(:order_receipt)
    Process.send_after(self(), :snapshot_equity, 5000)
    {:ok, %{strategies: %{}, initialized: false}}
  end

  @impl true
  def handle_call({:can_open?, strategy_id}, _from, state) do
    case Map.get(state.strategies, strategy_id) do
      nil -> {:reply, true, state}
      tracker ->
        can_trade = not tracker.daily_halted and not tracker.total_halted
        {:reply, can_trade, state}
    end
  end

  @impl true
  def handle_call({:reset, strategy_id}, _from, state) do
    case Map.get(state.strategies, strategy_id) do
      nil ->
        {:reply, :ok, state}
      tracker ->
        Logger.info("[CircuitBreaker] 🔓 Manual reset for Strategy #{strategy_id}")
        new_tracker = %{tracker |
          daily_halted: false,
          total_halted: false,
          peak_equity: tracker.current_equity,
          day_start_equity: tracker.current_equity
        }
        {:reply, :ok, %{state | strategies: Map.put(state.strategies, strategy_id, new_tracker)}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.strategies, state}
  end

  @impl true
  def handle_info(:snapshot_equity, state) do
    new_strategies =
      Enum.reduce(0..4, state.strategies, fn strategy_id, acc ->
        equity = calculate_equity(strategy_id)

        if equity > 0 do
          tracker = Map.get(acc, strategy_id, %{
            peak_equity: equity,
            day_start_equity: equity,
            current_equity: equity,
            daily_halted: false,
            total_halted: false
          })

          new_peak = max(tracker.peak_equity, equity)
          daily_drawdown = (equity - tracker.day_start_equity) / tracker.day_start_equity
          total_drawdown = (equity - new_peak) / new_peak

          daily_halted = tracker.daily_halted or (daily_drawdown < @daily_drawdown_limit)
          if daily_halted and not tracker.daily_halted do
            Logger.error("\n[CircuitBreaker] 🚨 DAILY BREAKER TRIPPED for Strategy #{strategy_id}! Drawdown: #{Float.round(daily_drawdown * 100, 2)}% (Limit: #{@daily_drawdown_limit * 100}%)\n")
          end

          total_halted = tracker.total_halted or (total_drawdown < @total_drawdown_limit)
          if total_halted and not tracker.total_halted do
            Logger.error("\n[CircuitBreaker] 🛑 TOTAL BREAKER TRIPPED for Strategy #{strategy_id}! Drawdown from peak: #{Float.round(total_drawdown * 100, 2)}% (Limit: #{@total_drawdown_limit * 100}%)\n")
          end

          Map.put(acc, strategy_id, %{
            peak_equity: new_peak,
            day_start_equity: tracker.day_start_equity,
            current_equity: equity,
            daily_halted: daily_halted,
            total_halted: total_halted
          })
        else
          acc
        end
      end)

    Process.send_after(self(), :snapshot_equity, 5000)
    {:noreply, %{state | strategies: new_strategies, initialized: true}}
  end

  @impl true
  def handle_info({:fact_asserted, :order_receipt, _rec}, state) do
    {:noreply, state}
  end

  defp calculate_equity(strategy_id) do
    port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: strategy_id}) |> List.first()

    if port != nil do
      positions = KnowledgeBase.get_by(:position, %{strategy_id: strategy_id})

      pos_value =
        Enum.reduce(positions, 0.0, fn pos, acc ->
          latest_md = KnowledgeBase.get_by(:market_data, %{symbol: pos.symbol}) |> List.last()
          price = if latest_md, do: latest_md.price, else: pos.avg_price
          acc + pos.quantity * price
        end)

      port.cash + pos_value
    else
      0.0
    end
  end
end
