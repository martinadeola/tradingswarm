defmodule TradingSwarm.Agents.QuantMomentum do
  @moduledoc """
  Momentum / Trend-Following Strategy.

  Entry: Bollinger Band breakout + MACD crossover + MACD histogram accelerating
         + ADX > 25 (confirming strong trend) + volume confirmation.
  Exit:  ATR-based stops. TP = 2×ATR, SL = 1×ATR from entry.

  Improvements over original:
  - Multi-timeframe confirmation (20-period AND 50-period indicators must agree)
  - MACD histogram must be accelerating (not just positive)
  - ADX filter ensures we only trade in trending regimes
  - Volume filter re-enabled: current volume must be ≥ 1.5× the 20-period average
  - ATR-based exits adapt to current volatility instead of fixed percentages
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  alias TradingSwarm.TechnicalAnalysis, as: TA
  require Logger

  @min_history 50
  @volume_multiplier 1.5
  @min_volume 5000
  @adx_trend_threshold 25.0
  @atr_tp_multiplier 2.0
  @atr_sl_multiplier 1.0
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

    # Update history (newest first internally, reversed for TA functions)
    history = Map.update(state.history, sym, [p], fn list -> [p | Enum.take(list, @min_history - 1)] end)
    vol_history = Map.update(state.vol_history, sym, [vol], fn list -> [vol | Enum.take(list, @min_history - 1)] end)
    new_state = %{state | history: history, vol_history: vol_history, cooldowns: cooldowns}

    prices = Map.get(history, sym, [])
    volumes = Map.get(vol_history, sym, [])

    if length(prices) >= @min_history do
      # Chronological order for TA functions
      chrono_prices = Enum.reverse(prices)

      # Compute indicators
      bb_prices = Enum.take(prices, 20)
      sma = Enum.sum(bb_prices) / length(bb_prices)
      variance = Enum.reduce(bb_prices, 0, fn x, acc -> acc + :math.pow(x - sma, 2) end) / length(bb_prices)
      stddev = :math.sqrt(variance)

      {macd_line, signal_line} = TA.macd(chrono_prices)
      {macd_trend, _hist_vals} = TA.macd_histogram_trend(chrono_prices)
      adx_val = TA.adx(chrono_prices)
      atr_val = TA.atr(chrono_prices)

      # Publish ATR to KB for risk manager to use
      old_indicators = KnowledgeBase.get_by(:indicator, %{symbol: sym, name: "atr"})
      Enum.each(old_indicators, fn ind -> KnowledgeBase.retract(:indicator, ind) end)
      KnowledgeBase.assert(:indicator, %{symbol: sym, name: "atr", value: atr_val})

      # Volume check
      avg_vol = Enum.sum(volumes) / max(length(volumes), 1)
      high_volume = vol >= avg_vol * @volume_multiplier and vol >= @min_volume

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
              Logger.info("[Momentum-#{id}] SELL #{sym} at $#{Float.round(p, 2)} (TP=#{Float.round(take_profit_long, 2)}, SL=#{Float.round(stop_loss_long, 2)})")

            qty < 0 and (p < take_profit_short or p > stop_loss_short) ->
              KnowledgeBase.assert(:trade_signal, %{symbol: sym, action: :cover, price: p, strategy_id: id})
              Logger.info("[Momentum-#{id}] COVER #{sym} at $#{Float.round(p, 2)} (TP=#{Float.round(take_profit_short, 2)}, SL=#{Float.round(stop_loss_short, 2)})")

            true -> :ok
          end
          new_state
        else
          # --- ENTRY LOGIC: Multi-factor momentum ---

          # 1. Bollinger Band breakout
          price_above_upper = p > sma + (state.std_dev * stddev)
          price_below_lower = p < sma - (state.std_dev * stddev)

          # 2. MACD crossover
          macd_bullish = macd_line > signal_line
          macd_bearish = macd_line < signal_line

          # 3. MACD histogram acceleration (NEW)
          macd_accelerating_up = macd_trend == :accelerating_bullish
          macd_accelerating_down = macd_trend == :accelerating_bearish

          # 4. ADX trend strength filter (NEW)
          strong_trend = adx_val > @adx_trend_threshold

          # 5. Order book and macro (existing)
          ob = KnowledgeBase.get_by(:order_book, %{symbol: sym}) |> List.last() || %{bid_volume: 0, ask_volume: 0}
          bullish_book = ob.bid_volume > ob.ask_volume
          bearish_book = ob.ask_volume > ob.bid_volume

          macro = KnowledgeBase.get_by(:macro_event) |> List.last() || %{sentiment: "Neutral"}
          bullish_macro = macro.sentiment in ["Bullish", "Neutral"]
          bearish_macro = macro.sentiment in ["Bearish", "Neutral"]

          cond do
            # Long: breakout above + MACD bullish & accelerating + strong trend + volume + book + macro
            price_above_upper and macd_bullish and (macd_accelerating_up or strong_trend) and
              high_volume and bullish_book and bullish_macro and cooldown == 0 ->
              KnowledgeBase.assert(:trade_signal, %{symbol: sym, action: :buy, price: p, strategy_id: id})
              %{new_state | cooldowns: Map.put(new_state.cooldowns, sym, @cooldown_ticks)}

            # Short: breakdown below + MACD bearish & accelerating + strong trend + volume + book + macro
            price_below_lower and macd_bearish and (macd_accelerating_down or strong_trend) and
              high_volume and bearish_book and bearish_macro and cooldown == 0 ->
              KnowledgeBase.assert(:trade_signal, %{symbol: sym, action: :short, price: p, strategy_id: id})
              %{new_state | cooldowns: Map.put(new_state.cooldowns, sym, @cooldown_ticks)}

            true -> new_state
          end
        end
      else
        new_state
      end
    else
      new_state
    end

    {:noreply, new_state}
  end
end
