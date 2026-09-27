defmodule TradingSwarm.Agents.Accountant do
  use GenServer
  alias TradingSwarm.KnowledgeBase

  @fee 0.00  # Simulated Zero-Commission Broker

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    KnowledgeBase.subscribe(:order_receipt)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:fact_asserted, :order_receipt, rec}, state) do
    port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: rec.strategy_id}) |> List.first()
    pos = KnowledgeBase.get_by(:position, %{symbol: rec.symbol, strategy_id: rec.strategy_id}) |> List.first()

    if port do
      process_order(rec.action, rec, port, pos)
    end

    KnowledgeBase.retract(:order_receipt, rec)
    {:noreply, state}
  end

  # --- Order Processing Handlers ---

  defp process_order(:buy, rec, port, nil) do
    cost = rec.quantity * rec.price + @fee
    update_cash(rec.strategy_id, port.cash - cost)

    KnowledgeBase.assert(:position, %{
      symbol: rec.symbol,
      quantity: rec.quantity,
      avg_price: rec.price,
      strategy_id: rec.strategy_id
    })
  end

  defp process_order(:buy, rec, port, pos) do
    cost = rec.quantity * rec.price + @fee
    update_cash(rec.strategy_id, port.cash - cost)

    new_qty = pos.quantity + rec.quantity

    cond do
      new_qty == 0 ->
        KnowledgeBase.retract(:position, pos)

      true ->
        new_avg = calc_weighted_avg(pos.quantity, pos.avg_price, rec.quantity, rec.price, new_qty)

        KnowledgeBase.update(
          :position,
          %{symbol: rec.symbol, strategy_id: rec.strategy_id},
          %{quantity: new_qty, avg_price: new_avg}
        )
    end
  end

  defp process_order(:sell, rec, port, %{quantity: q} = pos) when q > 0 do
    revenue = rec.quantity * rec.price - @fee
    update_cash(rec.strategy_id, port.cash + revenue)

    new_qty = q - rec.quantity

    if new_qty <= 0 do
      KnowledgeBase.retract(:position, pos)
    else
      KnowledgeBase.update(
        :position,
        %{symbol: rec.symbol, strategy_id: rec.strategy_id},
        %{quantity: new_qty}
      )
    end
  end

  defp process_order(:short, rec, port, nil) do
    revenue = rec.quantity * rec.price - @fee
    update_cash(rec.strategy_id, port.cash + revenue)

    KnowledgeBase.assert(:position, %{
      symbol: rec.symbol,
      quantity: -rec.quantity,
      avg_price: rec.price,
      strategy_id: rec.strategy_id
    })
  end

  defp process_order(:short, rec, port, pos) do
    revenue = rec.quantity * rec.price - @fee
    update_cash(rec.strategy_id, port.cash + revenue)

    new_qty = pos.quantity - rec.quantity

    cond do
      new_qty == 0 ->
        KnowledgeBase.retract(:position, pos)

      true ->
        new_avg = calc_short_avg(pos.quantity, pos.avg_price, rec.quantity, rec.price, new_qty)

        KnowledgeBase.update(
          :position,
          %{symbol: rec.symbol, strategy_id: rec.strategy_id},
          %{quantity: new_qty, avg_price: new_avg}
        )
    end
  end

  defp process_order(:cover, rec, port, %{quantity: q} = pos) when q < 0 do
    cost = rec.quantity * rec.price + @fee
    update_cash(rec.strategy_id, port.cash - cost)

    new_qty = q + rec.quantity

    if new_qty >= 0 do
      KnowledgeBase.retract(:position, pos)
    else
      KnowledgeBase.update(
        :position,
        %{symbol: rec.symbol, strategy_id: rec.strategy_id},
        %{quantity: new_qty}
      )
    end
  end

  # Fallback for unrecognized action or invalid position state (e.g. phantom cover/sell)
  defp process_order(_action, _rec, _port, _pos), do: :ok

  # --- Helpers ---

  defp update_cash(strategy_id, new_cash) do
    KnowledgeBase.update(:portfolio_state, %{strategy_id: strategy_id}, %{cash: new_cash})
  end

  defp calc_weighted_avg(pos_qty, pos_avg, add_qty, add_price, new_qty) do
    if pos_qty * add_qty < 0 do
      if abs(new_qty) < abs(pos_qty), do: pos_avg, else: add_price
    else
      (pos_qty * pos_avg + add_qty * add_price) / new_qty
    end
  end

  defp calc_short_avg(pos_qty, pos_avg, add_qty, add_price, new_qty) do
    if pos_qty * -add_qty < 0 do
      if abs(new_qty) < abs(pos_qty), do: pos_avg, else: add_price
    else
      (abs(pos_qty) * pos_avg + add_qty * add_price) / abs(new_qty)
    end
  end
end
