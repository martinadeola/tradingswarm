defmodule TradingSwarm.Agents.ExchangeMatcher do
  @moduledoc """
  Simulates realistic exchange order matching with:

  1. Dynamic spreads: spread = max(0.01, price × 0.0002 + random jitter)
  2. Price impact: large orders shift fill price by 0.01% × (order_size / tick_volume)
  3. Partial fills: orders > 20% of tick volume get partially filled
  4. Fill latency: orders don't fill on the same tick (1-tick delay via pending_age tracking)

  This replaces the naive fixed $0.05 spread model.
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase

  @spread_base_pct 0.0002      # 2 basis points base spread
  @spread_min 0.01             # Minimum spread in dollars
  @impact_coefficient 0.0001   # Price impact per unit of volume ratio
  @partial_fill_threshold 0.20 # Orders > 20% of tick volume get partial fills
  @min_fill_ratio 0.30         # Minimum 30% of order filled in partial fill

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    KnowledgeBase.subscribe(:market_data)
    # Track when orders were placed (for fill latency)
    {:ok, %{order_ticks: %{}}}
  end

  @impl true
  def handle_info({:fact_asserted, :market_data, md}, state) do
    sym = md.symbol
    current_price = md.price
    tick_volume = max(md.volume, 100)  # Prevent division by zero

    # Dynamic spread calculation
    jitter = (:rand.uniform() - 0.5) * 0.02  # ±$0.01 random jitter
    spread = max(@spread_min, current_price * @spread_base_pct + jitter)
    ask_price = current_price + (spread / 2.0)
    bid_price = current_price - (spread / 2.0)

    # Check all pending orders for this symbol
    pending_orders = KnowledgeBase.get_by(:pending_order, %{symbol: sym})

    new_order_ticks =
      Enum.reduce(pending_orders, state.order_ticks, fn pending, acc_ticks ->
        order_key = {pending.symbol, pending.action, pending.strategy_id}
        ticks_pending = Map.get(acc_ticks, order_key, 0)

        # Fill latency: skip orders placed on this tick (need at least 1 tick delay)
        if ticks_pending < 1 do
          Map.put(acc_ticks, order_key, ticks_pending + 1)
        else
          act = pending.action
          limit = pending.limit_price
          qty = pending.quantity
          id = pending.strategy_id

          case match_price(act, ask_price, bid_price, limit) do
            {:fill, base_fill_price} ->
              # Price impact: large orders move the market
              volume_ratio = qty / tick_volume
              impact = current_price * @impact_coefficient * volume_ratio
              fill_price = apply_price_impact(base_fill_price, impact, act)

              # Partial fill logic
              {fill_qty, remaining_qty} = calculate_fill_quantity(qty, volume_ratio)

              # Emit order receipt for filled portion
              KnowledgeBase.assert(:order_receipt, %{
                symbol: sym,
                action: act,
                quantity: fill_qty,
                price: Float.round(fill_price, 4),
                time: md.time,
                strategy_id: id
              })

              if remaining_qty > 0 do
                # Update pending order with remaining quantity
                KnowledgeBase.retract(:pending_order, pending)
                KnowledgeBase.assert(:pending_order, %{
                  symbol: sym,
                  action: act,
                  quantity: remaining_qty,
                  limit_price: limit,
                  strategy_id: id
                })
                acc_ticks  # Keep tracking this order
              else
                # Fully filled — remove pending order
                KnowledgeBase.retract(:pending_order, pending)
                Map.delete(acc_ticks, order_key)
              end

            :no_fill ->
              # Order not fillable yet — increment tick counter
              Map.put(acc_ticks, order_key, ticks_pending + 1)
          end
        end
      end)

    {:noreply, %{state | order_ticks: new_order_ticks}}
  end

  # --- Private Matching & Pricing Helpers ---

  defp match_price(act, ask_price, _bid_price, limit) when act in [:buy, :cover] and ask_price <= limit do
    {:fill, ask_price}
  end

  defp match_price(act, _ask_price, bid_price, limit) when act in [:sell, :short] and bid_price >= limit do
    {:fill, bid_price}
  end

  defp match_price(_act, _ask, _bid, _limit), do: :no_fill

  defp apply_price_impact(price, impact, act) when act in [:buy, :cover], do: price + impact
  defp apply_price_impact(price, impact, act) when act in [:sell, :short], do: price - impact

  defp calculate_fill_quantity(qty, volume_ratio) when volume_ratio > @partial_fill_threshold do
    fill_ratio = max(@min_fill_ratio, 1.0 - (volume_ratio - @partial_fill_threshold))
    filled = max(1, trunc(qty * fill_ratio))
    {filled, qty - filled}
  end

  defp calculate_fill_quantity(qty, _volume_ratio), do: {qty, 0}
end
