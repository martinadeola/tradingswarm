defmodule TradingSwarm.Agents.MetaAgent do
  @moduledoc """
  The Meta-Agent evaluates competing strategy performance using risk-adjusted metrics
  and mirrors the best-performing strategy's trades to the real-money portfolio (Strategy 0).

  Scoring: Uses Sharpe Ratio from the PerformanceTracker instead of raw cash balance.
  Stability: Requires a new leader to beat the current leader's Sharpe by at least 0.3.
  Minimum Evaluation: Won't crown a leader until at least 50 equity snapshots exist.
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  alias TradingSwarm.PerformanceTracker
  require Logger

  @min_snapshots 50         # Minimum data points before evaluating
  @sharpe_threshold 0.3     # New leader must beat current by this margin
  @evaluation_interval 10_000  # 10 seconds between evaluations

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Process.send_after(self(), :evaluate, 5000)
    KnowledgeBase.subscribe(:trade_signal)

    {:ok, %{leader_transitions: []}}
  end

  @impl true
  def handle_info(:evaluate, state) do
    meta = KnowledgeBase.get_by(:meta_strategy) |> List.first()

    new_state =
      if meta != nil do
        current_leader = meta.leader_id

        # Collect Sharpe ratios for all virtual strategies (1..4)
        strategy_metrics =
          Enum.map(1..4, fn id ->
            sharpe = PerformanceTracker.get_sharpe(id)
            snapshots = PerformanceTracker.snapshot_count(id)
            {id, sharpe, snapshots}
          end)

        # Only consider strategies with enough data
        eligible =
          Enum.filter(strategy_metrics, fn {_id, _sharpe, snapshots} ->
            snapshots >= @min_snapshots
          end)

        if length(eligible) > 0 do
          # Find the best strategy by Sharpe ratio
          {best_id, best_sharpe, _} = Enum.max_by(eligible, fn {_id, sharpe, _} -> sharpe end)

          current_sharpe =
            case Enum.find(eligible, fn {id, _, _} -> id == current_leader end) do
              nil -> -999.0
              {_, sharpe, _} -> sharpe
            end

          # Only switch if the improvement is significant
          if best_id != current_leader and (best_sharpe - current_sharpe) > @sharpe_threshold do
            Logger.info("""
            \n[META-AGENT] 👑 Regime Shift Detected!
              Crowning Strategy #{best_id} as the new LEADER.
              Sharpe: #{Float.round(best_sharpe, 3)} vs old leader #{current_leader}'s #{Float.round(current_sharpe, 3)}
              Margin: #{Float.round(best_sharpe - current_sharpe, 3)} (threshold: #{@sharpe_threshold})
            """)

            KnowledgeBase.update(:meta_strategy, %{leader_id: current_leader}, %{leader_id: best_id})

            transition = %{
              from: current_leader,
              to: best_id,
              old_sharpe: current_sharpe,
              new_sharpe: best_sharpe,
              time: DateTime.utc_now()
            }

            %{state | leader_transitions: [transition | state.leader_transitions]}
          else
            # Log periodic status
            if :rand.uniform(6) == 1 do
              rankings =
                eligible
                |> Enum.sort_by(fn {_id, sharpe, _} -> -sharpe end)
                |> Enum.map(fn {id, sharpe, snaps} ->
                  marker = if id == current_leader, do: " 👑", else: ""
                  "  Strategy #{id}: Sharpe=#{Float.round(sharpe, 3)} (#{snaps} snapshots)#{marker}"
                end)
                |> Enum.join("\n")

              Logger.info("\n[META-AGENT] Strategy Rankings:\n#{rankings}")
            end

            state
          end
        else
          state
        end
      else
        state
      end

    Process.send_after(self(), :evaluate, @evaluation_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:fact_asserted, :trade_signal, sig}, state) do
    meta = KnowledgeBase.get_by(:meta_strategy) |> List.first()

    # DO NOT process signals that were already cloned for Strategy 0
    if meta != nil and sig.strategy_id != 0 do
      is_leader = sig.strategy_id == meta.leader_id

      should_clone =
        case sig.action do
          :buy ->
            pos = KnowledgeBase.get_by(:position, %{symbol: sig.symbol, strategy_id: 0}) |> List.first()
            is_leader and pos == nil

          :short ->
            pos = KnowledgeBase.get_by(:position, %{symbol: sig.symbol, strategy_id: 0}) |> List.first()
            is_leader and pos == nil

          :sell ->
            pos = KnowledgeBase.get_by(:position, %{symbol: sig.symbol, strategy_id: 0}) |> List.first()
            pos != nil and pos.quantity > 0

          :cover ->
            pos = KnowledgeBase.get_by(:position, %{symbol: sig.symbol, strategy_id: 0}) |> List.first()
            pos != nil and pos.quantity < 0

          _ ->
            false
        end

      if should_clone do
        # Clone for Real Money (Strategy 0)
        KnowledgeBase.assert(:trade_signal, %{
          symbol: sig.symbol,
          action: sig.action,
          price: sig.price,
          strategy_id: 0
        })
      end
    end

    {:noreply, state}
  end
end
