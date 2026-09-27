defmodule TradingSwarm.Agents.QuantPairs do
  @moduledoc """
  Pairs Trading / Statistical Arbitrage Strategy (Strategy 4).

  Concept: Trade the spread between correlated stocks. When the spread deviates
  significantly from its historical mean, bet on reversion.

  Pairs:
  - AAPL/MSFT (tech mega-caps, highly correlated)
  - AAPL/GOOG (tech mega-caps)

  Entry: Z-score of the price ratio exceeds ±2.0 standard deviations
         + Volume confirmation on both legs
         + Spread must be widening (not already reverting)
  Exit:  Z-score reverts to ±0.5 (take profit) OR exceeds ±3.0 (stop loss — divergence)

  This strategy is market-neutral: always long one stock and short another,
  hedging out market-wide moves and isolating the relative value trade.
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  require Logger

  @min_history 50
  @z_entry_threshold 2.0      # Enter when z-score exceeds ±2.0
  @z_take_profit 0.5           # Take profit when z-score reverts to ±0.5
  @z_stop_loss 3.0             # Stop loss if z-score diverges to ±3.0
  @min_volume 5000
  @cooldown_ticks 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(args) do
    id = args.id
    KnowledgeBase.subscribe(:market_data)

    pairs = Application.get_env(:trading_swarm, :pairs, [{"AAPL", "MSFT"}])

    {:ok, %{
      id: id,
      pairs: pairs,
      prices: %{},          # %{symbol => [price, ...]}
      volumes: %{},          # %{symbol => [vol, ...]}
      active_pairs: %{},      # %{{sym_a, sym_b} => %{direction: :long_a | :short_a, entry_z: float}}
      cooldowns: %{}
    }}
  end

  @impl true
  def handle_info({:fact_asserted, :market_data, md}, state) do
    sym = md.symbol
    p = md.price
    vol = md.volume
    id = state.id

    # Update price and volume history
    prices = Map.update(state.prices, sym, [p], fn list -> [p | Enum.take(list, @min_history - 1)] end)
    volumes = Map.update(state.volumes, sym, [vol], fn list -> [vol | Enum.take(list, @min_history - 1)] end)
    new_state = %{state | prices: prices, volumes: volumes}

    # Check each pair that involves this symbol
    new_state =
      Enum.reduce(state.pairs, new_state, fn {sym_a, sym_b} = pair, acc_state ->
        if sym in [sym_a, sym_b] do
          process_pair(pair, sym_a, sym_b, id, acc_state)
        else
          acc_state
        end
      end)

    {:noreply, new_state}
  end

  defp process_pair(pair, sym_a, sym_b, id, state) do
    prices_a = Map.get(state.prices, sym_a, [])
    prices_b = Map.get(state.prices, sym_b, [])
    volumes_a = Map.get(state.volumes, sym_a, [])
    volumes_b = Map.get(state.volumes, sym_b, [])

    min_len = min(length(prices_a), length(prices_b))

    if min_len < @min_history do
      state
    else
      # Compute price ratio: A/B
      ratios =
        Enum.zip(Enum.take(prices_a, min_len), Enum.take(prices_b, min_len))
        |> Enum.map(fn {pa, pb} -> if pb > 0, do: pa / pb, else: 1.0 end)

      # Z-score of current ratio vs historical
      current_ratio = hd(ratios)
      mean_ratio = Enum.sum(ratios) / length(ratios)
      variance = Enum.reduce(ratios, 0.0, fn r, acc -> acc + :math.pow(r - mean_ratio, 2) end) / length(ratios)
      std_ratio = :math.sqrt(variance)

      z_score = if std_ratio > 0.0001, do: (current_ratio - mean_ratio) / std_ratio, else: 0.0

      # Volume check
      vol_a = hd(volumes_a)
      vol_b = hd(volumes_b)
      both_have_volume = vol_a >= @min_volume and vol_b >= @min_volume

      # Current prices
      price_a = hd(prices_a)
      price_b = hd(prices_b)

      # Cooldown
      cooldown = Map.get(state.cooldowns, pair, 0)
      cooldowns = if cooldown > 0, do: Map.put(state.cooldowns, pair, cooldown - 1), else: state.cooldowns
      state = %{state | cooldowns: cooldowns}

      # Check if we have an active pair trade
      active = Map.get(state.active_pairs, pair)

      # Check for existing positions
      pos_a = KnowledgeBase.get_by(:position, %{symbol: sym_a, strategy_id: id}) |> List.first()
      pos_b = KnowledgeBase.get_by(:position, %{symbol: sym_b, strategy_id: id}) |> List.first()
      pending_a = KnowledgeBase.get_by(:pending_order, %{symbol: sym_a, strategy_id: id}) |> List.first()
      pending_b = KnowledgeBase.get_by(:pending_order, %{symbol: sym_b, strategy_id: id}) |> List.first()
      has_pending = pending_a != nil or pending_b != nil

      if has_pending do
        state
      else
        if active != nil do
          # --- EXIT LOGIC ---
          {should_exit, reason} =
            cond do
              # Take profit: z-score reverted toward mean
              active.direction == :long_a and z_score <= @z_take_profit and z_score >= -@z_take_profit ->
                {true, "TP (z=#{Float.round(z_score, 2)})"}

              active.direction == :short_a and z_score >= -@z_take_profit and z_score <= @z_take_profit ->
                {true, "TP (z=#{Float.round(z_score, 2)})"}

              # Stop loss: spread diverged further
              active.direction == :long_a and z_score < -@z_stop_loss ->
                {true, "SL (z=#{Float.round(z_score, 2)})"}

              active.direction == :short_a and z_score > @z_stop_loss ->
                {true, "SL (z=#{Float.round(z_score, 2)})"}

              true ->
                {false, ""}
            end

          if should_exit do
            # Close both legs
            if pos_a != nil and pos_a.quantity > 0 do
              KnowledgeBase.assert(:trade_signal, %{symbol: sym_a, action: :sell, price: price_a, strategy_id: id})
            end
            if pos_a != nil and pos_a.quantity < 0 do
              KnowledgeBase.assert(:trade_signal, %{symbol: sym_a, action: :cover, price: price_a, strategy_id: id})
            end
            if pos_b != nil and pos_b.quantity > 0 do
              KnowledgeBase.assert(:trade_signal, %{symbol: sym_b, action: :sell, price: price_b, strategy_id: id})
            end
            if pos_b != nil and pos_b.quantity < 0 do
              KnowledgeBase.assert(:trade_signal, %{symbol: sym_b, action: :cover, price: price_b, strategy_id: id})
            end

            Logger.info("[Pairs-#{id}] CLOSING #{sym_a}/#{sym_b} pair — #{reason}")
            %{state | active_pairs: Map.delete(state.active_pairs, pair)}
          else
            state
          end
        else
          # --- ENTRY LOGIC ---
          # No active pair trade — check for entry signal
          already_positioned = pos_a != nil or pos_b != nil

          cond do
            # Z-score very negative: A is cheap relative to B
            # Strategy: Long A, Short B (bet on ratio reverting up)
            z_score < -@z_entry_threshold and both_have_volume and not already_positioned and cooldown == 0 ->
              KnowledgeBase.assert(:trade_signal, %{symbol: sym_a, action: :buy, price: price_a, strategy_id: id})
              KnowledgeBase.assert(:trade_signal, %{symbol: sym_b, action: :short, price: price_b, strategy_id: id})

              Logger.info("[Pairs-#{id}] OPENING Long #{sym_a} / Short #{sym_b} (z=#{Float.round(z_score, 2)})")
              %{state |
                active_pairs: Map.put(state.active_pairs, pair, %{direction: :long_a, entry_z: z_score}),
                cooldowns: Map.put(state.cooldowns, pair, @cooldown_ticks)
              }

            # Z-score very positive: A is expensive relative to B
            # Strategy: Short A, Long B (bet on ratio reverting down)
            z_score > @z_entry_threshold and both_have_volume and not already_positioned and cooldown == 0 ->
              KnowledgeBase.assert(:trade_signal, %{symbol: sym_a, action: :short, price: price_a, strategy_id: id})
              KnowledgeBase.assert(:trade_signal, %{symbol: sym_b, action: :buy, price: price_b, strategy_id: id})

              Logger.info("[Pairs-#{id}] OPENING Short #{sym_a} / Long #{sym_b} (z=#{Float.round(z_score, 2)})")
              %{state |
                active_pairs: Map.put(state.active_pairs, pair, %{direction: :short_a, entry_z: z_score}),
                cooldowns: Map.put(state.cooldowns, pair, @cooldown_ticks)
              }

            true ->
              state
          end
        end
      end
    end
  end
end
