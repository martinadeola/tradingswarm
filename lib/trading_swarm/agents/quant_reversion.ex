defmodule TradingSwarm.Agents.QuantReversion do
  @moduledoc """
  Mean Reversion Strategy.

  Entry: Price at Bollinger Band extremes + RSI oversold/overbought (< 20 / > 80)
         + Regime filter (low ADX = range-bound market)
         + RSI divergence confirmation (2 consecutive extreme readings)
         + Volume confirmation.
  Exit:  ATR-based stops. TP = reversion toward SMA (2×ATR), SL = 1.5×ATR.

  Improvements over original:
  - RSI thresholds tightened to < 20 / > 80 (was 25/75) for higher conviction
  - Regime filter: only trades when ADX < 25 (range-bound, where reversion works)
  - RSI divergence: requires RSI to be extreme for 2+ consecutive bars
  - Volume filter re-enabled
  - ATR-based exits
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  alias TradingSwarm.TechnicalAnalysis, as: TA
  require Logger

  @min_history 50
  @volume_multiplier 1.5
  @min_volume 5000
  @rsi_oversold 20.0
  @rsi_overbought 80.0
  @adx_rangebound_threshold 25.0  # Only trade when ADX is BELOW this
  @atr_tp_multiplier 2.0
  @atr_sl_multiplier 1.5
  @cooldown_ticks 5

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(args) do
    id = args.id
    KnowledgeBase.subscribe(:market_data)

    {:ok, %{
      id: id,
      std_dev: args.std_dev,
      vol_thresh: args.volume_threshold,
      history: %{},
      vol_history: %{},
      rsi_history: %{},   # Track consecutive RSI readings per symbol
      cooldowns: %{}
    }}
  end

  @impl true
  def handle_info({:fact_asserted, :market_data, md}, state) do
    sym = md.symbol
    p = md.price
    vol = md.volume
    id = state.id

    # Decrement cooldown
    cooldown = Map.get(state.cooldowns, sym, 0)
    cooldowns = if cooldown > 0, do: Map.put(state.cooldowns, sym, cooldown - 1), else: state.cooldowns

    history = Map.update(state.history, sym, [p], fn list -> [p | Enum.take(list, @min_history - 1)] end)
    vol_history = Map.update(state.vol_history, sym, [vol], fn list -> [vol | Enum.take(list, @min_history - 1)] end)
    new_state = %{state | history: history, vol_history: vol_history, cooldowns: cooldowns}

    prices = Map.get(history, sym, [])
    volumes = Map.get(vol_history, sym, [])

    if length(prices) >= @min_history do
      chrono_prices = Enum.reverse(prices)

      # Compute indicators
      bb_prices = Enum.take(prices, 20)
      sma = Enum.sum(bb_prices) / length(bb_prices)
      variance = Enum.reduce(bb_prices, 0, fn x, acc -> acc + :math.pow(x - sma, 2) end) / length(bb_prices)
      stddev = :math.sqrt(variance)

      rsi_val = TA.rsi(chrono_prices)
      adx_val = TA.adx(chrono_prices)
      atr_val = TA.atr(chrono_prices)

      # Publish ATR for risk manager
      old_indicators = KnowledgeBase.get_by(:indicator, %{symbol: sym, name: "atr"})
      Enum.each(old_indicators, fn ind -> KnowledgeBase.retract(:indicator, ind) end)
      KnowledgeBase.assert(:indicator, %{symbol: sym, name: "atr", value: atr_val})

      # Track RSI history for divergence confirmation
      rsi_hist = Map.get(new_state.rsi_history, sym, [])
      rsi_hist = [rsi_val | Enum.take(rsi_hist, 4)]  # Keep last 5

      # RSI divergence: at least 2 consecutive extreme readings
      consecutive_oversold = length(rsi_hist) >= 2 and
        Enum.at(rsi_hist, 0) < @rsi_oversold and Enum.at(rsi_hist, 1) < @rsi_oversold
      consecutive_overbought = length(rsi_hist) >= 2 and
        Enum.at(rsi_hist, 0) > @rsi_overbought and Enum.at(rsi_hist, 1) > @rsi_overbought

      # Volume check
      avg_vol = Enum.sum(volumes) / max(length(volumes), 1)
      high_volume = vol >= avg_vol * @volume_multiplier and vol >= @min_volume

      # Regime filter: only trade when market is range-bound
      range_bound = adx_val < @adx_rangebound_threshold

      pos = KnowledgeBase.get_by(:position, %{symbol: sym, strategy_id: id}) |> List.first()
      pending = KnowledgeBase.get_by(:pending_order, %{symbol: sym, strategy_id: id}) |> List.first()

      final_state = %{new_state | rsi_history: Map.put(new_state.rsi_history, sym, rsi_hist)}

      final_state =
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
                Logger.info("[Reversion-#{id}] SELL #{sym} at $#{Float.round(p, 2)}")

              qty < 0 and (p < take_profit_short or p > stop_loss_short) ->
                KnowledgeBase.assert(:trade_signal, %{symbol: sym, action: :cover, price: p, strategy_id: id})
                Logger.info("[Reversion-#{id}] COVER #{sym} at $#{Float.round(p, 2)}")

              true -> :ok
            end
            final_state
          else
            # --- ENTRY LOGIC: Mean Reversion ---
            near_lower_band = p < sma - (state.std_dev * stddev)
            near_upper_band = p > sma + (state.std_dev * stddev)

            ob = KnowledgeBase.get_by(:order_book, %{symbol: sym}) |> List.last() || %{bid_volume: 0, ask_volume: 0}
            bullish_book = ob.bid_volume > ob.ask_volume
            bearish_book = ob.ask_volume > ob.bid_volume

            macro = KnowledgeBase.get_by(:macro_event) |> List.last() || %{sentiment: "Neutral"}

            cond do
              # Long: oversold + at lower band + range-bound regime + RSI divergence + volume
              near_lower_band and consecutive_oversold and range_bound and
                high_volume and bullish_book and macro.sentiment != "Bearish" and cooldown == 0 ->
                KnowledgeBase.assert(:trade_signal, %{symbol: sym, action: :buy, price: p, strategy_id: id})
                %{final_state | cooldowns: Map.put(final_state.cooldowns, sym, @cooldown_ticks)}

              # Short: overbought + at upper band + range-bound regime + RSI divergence + volume
              near_upper_band and consecutive_overbought and range_bound and
                high_volume and bearish_book and macro.sentiment != "Bullish" and cooldown == 0 ->
                KnowledgeBase.assert(:trade_signal, %{symbol: sym, action: :short, price: p, strategy_id: id})
                %{final_state | cooldowns: Map.put(final_state.cooldowns, sym, @cooldown_ticks)}

              true -> final_state
            end
          end
        else
          final_state
        end

      {:noreply, final_state}
    else
      {:noreply, new_state}
    end
  end
end

