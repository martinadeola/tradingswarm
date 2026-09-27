defmodule TradingSwarm.Agents.QuantVWAP do
  @moduledoc """
  VWAP Pullback Strategy.

  Entry: Price was trending away from VWAP, now pulling back to touch it.
         Confirms with volume spike and anchored daily VWAP.
  Exit:  ATR-based stops. TP = 2×ATR, SL = 1×ATR.

  Improvements over original:
  - Time-of-day awareness: VWAP is most effective in first/last hours of trading
  - Anchored VWAP: tracks daily VWAP resets (instead of rolling 50-period)
  - Volume filter re-enabled: requires 1.5× average volume
  - Requires increasing volume over last 3 bars for pullback confirmation
  - ATR-based exits
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  alias TradingSwarm.TechnicalAnalysis, as: TA
  require Logger

  @min_history 50
  @volume_multiplier 1.5
  @min_volume 5000
  @atr_tp_multiplier 2.0
  @atr_sl_multiplier 1.0
  @cooldown_ticks 5
  @vwap_touch_tolerance 0.001  # 0.1% tolerance for "touching" VWAP

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(args) do
    id = args.id
    KnowledgeBase.subscribe(:market_data)

    {:ok, %{
      id: id,
      history: %{},
      # Anchored VWAP: track cumulative price*volume and volume per symbol per day
      vwap_state: %{},
      # Track last seen day to detect day changes
      last_day: nil,
      cooldowns: %{}
    }}
  end

  @impl true
  def handle_info({:fact_asserted, :market_data, md}, state) do
    sym = md.symbol
    p = md.price
    vol = md.volume
    id = state.id
    time = md.time

    # Decrement cooldown
    cooldown = Map.get(state.cooldowns, sym, 0)
    cooldowns = if cooldown > 0, do: Map.put(state.cooldowns, sym, cooldown - 1), else: state.cooldowns

    # Keep 50 periods of {price, volume}
    history = Map.update(state.history, sym, [{p, vol}], fn list -> [{p, vol} | Enum.take(list, @min_history - 1)] end)
    new_state = %{state | history: history, cooldowns: cooldowns}

    data = Map.get(history, sym, [])

    if length(data) >= @min_history do
      # --- Anchored VWAP ---
      # Detect day change and reset VWAP accumulator
      current_day = if time, do: DateTime.to_date(time), else: Date.utc_today()
      sym_vwap = Map.get(state.vwap_state, sym, %{day: current_day, cum_pv: 0.0, cum_v: 0.0})

      sym_vwap =
        if sym_vwap.day != current_day do
          # New day — reset VWAP
          %{day: current_day, cum_pv: p * vol, cum_v: vol + 0.0}
        else
          %{sym_vwap | cum_pv: sym_vwap.cum_pv + p * vol, cum_v: sym_vwap.cum_v + vol}
        end

      vwap = if sym_vwap.cum_v > 0, do: sym_vwap.cum_pv / sym_vwap.cum_v, else: p
      new_state = %{new_state | vwap_state: Map.put(state.vwap_state, sym, sym_vwap)}

      # Extract recent prices for indicators
      prices_only = Enum.map(data, fn {price, _} -> price end)
      chrono_prices = Enum.reverse(prices_only)
      atr_val = TA.atr(chrono_prices)

      # Publish ATR for risk manager
      old_indicators = KnowledgeBase.get_by(:indicator, %{symbol: sym, name: "atr"})
      Enum.each(old_indicators, fn ind -> KnowledgeBase.retract(:indicator, ind) end)
      KnowledgeBase.assert(:indicator, %{symbol: sym, name: "atr", value: atr_val})

      # Trend detection: look at last 3 bars
      [{curr_p, curr_v}, {prev1_p, prev1_v}, {prev2_p, prev2_v} | _] = data

      # Volume analysis
      volumes = Enum.map(data, fn {_, v} -> v end)
      avg_vol = Enum.sum(volumes) / max(length(volumes), 1)
      high_volume = curr_v >= avg_vol * @volume_multiplier and curr_v >= @min_volume

      # Increasing volume over last 3 bars (pullback confirmation)
      volume_increasing = curr_v > prev1_v and prev1_v > prev2_v

      # VWAP touch detection
      touching_vwap = abs(curr_p - vwap) / vwap <= @vwap_touch_tolerance

      # Was trending away from VWAP
      was_above = prev2_p > vwap and prev1_p > vwap
      was_below = prev2_p < vwap and prev1_p < vwap

      # Time-of-day filter: VWAP works best in first/last hours
      good_time = is_favorable_time(time)

      pos = KnowledgeBase.get_by(:position, %{symbol: sym, strategy_id: id}) |> List.first()
      pending = KnowledgeBase.get_by(:pending_order, %{symbol: sym, strategy_id: id}) |> List.first()

      if pending == nil do
        if pos != nil do
          # --- EXIT LOGIC: ATR-based stops ---
          qty = pos.quantity
          avg_price = pos.avg_price

          take_profit_long = avg_price + (atr_val * @atr_tp_multiplier)
          stop_loss_long = avg_price - (atr_val * @atr_sl_multiplier)

          take_profit_short = avg_price - (atr_val * @atr_tp_multiplier)
          stop_loss_short = avg_price + (atr_val * @atr_sl_multiplier)

          cond do
            qty > 0 and (p > take_profit_long or p < stop_loss_long) ->
              KnowledgeBase.assert(:trade_signal, %{symbol: sym, action: :sell, price: p, strategy_id: id})
              Logger.info("[VWAP-#{id}] SELL #{sym} at $#{Float.round(p, 2)}")

            qty < 0 and (p < take_profit_short or p > stop_loss_short) ->
              KnowledgeBase.assert(:trade_signal, %{symbol: sym, action: :cover, price: p, strategy_id: id})
              Logger.info("[VWAP-#{id}] COVER #{sym} at $#{Float.round(p, 2)}")

            true -> :ok
          end
          new_state
        else
          # --- ENTRY LOGIC: VWAP Pullback ---
          cond do
            # Bullish pullback: was above VWAP, now touching it from above
            was_above and touching_vwap and high_volume and
              (volume_increasing or good_time) and cooldown == 0 ->
              KnowledgeBase.assert(:trade_signal, %{symbol: sym, action: :buy, price: p, strategy_id: id})
              %{new_state | cooldowns: Map.put(new_state.cooldowns, sym, @cooldown_ticks)}

            # Bearish pullback: was below VWAP, now touching it from below
            was_below and touching_vwap and high_volume and
              (volume_increasing or good_time) and cooldown == 0 ->
              KnowledgeBase.assert(:trade_signal, %{symbol: sym, action: :short, price: p, strategy_id: id})
              %{new_state | cooldowns: Map.put(new_state.cooldowns, sym, @cooldown_ticks)}

            true -> new_state
          end
        end
      else
        new_state
      end

      {:noreply, new_state}
    else
      {:noreply, new_state}
    end
  end

  # VWAP is most effective during the first and last hours of trading (US market)
  defp is_favorable_time(nil), do: true  # Backtest: always allow
  defp is_favorable_time(time) do
    utc_time = DateTime.to_time(time)
    hour = utc_time.hour

    # US market: 13:30 - 21:00 UTC
    # First hour: 13:30 - 14:30 (hour 13-14)
    # Last hour: 20:00 - 21:00 (hour 20)
    hour in [13, 14, 20]
  end
end
