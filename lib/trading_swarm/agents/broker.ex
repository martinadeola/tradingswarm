defmodule TradingSwarm.Agents.Broker do
  @moduledoc """
  Execution agent that interfaces with the market.

  This is a demonstration, so execution is entirely
  simulated. It creates pending orders in the KnowledgeBase for the
  ExchangeMatcher to fill.

  The broker only processes :approved_order facts from the risk manager.
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    KnowledgeBase.subscribe(:approved_order)
    Logger.info("[Broker] Starting in simulated execution mode")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:fact_asserted, :approved_order, order}, state) do
    execute_simulated(order)
    KnowledgeBase.retract(:approved_order, order)
    {:noreply, state}
  end



  defp execute_simulated(order) do
    action_str = order.action |> to_string() |> String.upcase()
    order_type_str = order.order_type |> to_string() |> String.capitalize()
    Logger.info("[Broker-#{order.strategy_id}] #{action_str} #{order.quantity}x #{order.symbol} at $#{Float.round(order.price, 2)} (#{order_type_str}) [SIMULATED]")

    KnowledgeBase.assert(:pending_order, %{
      symbol: order.symbol,
      action: order.action,
      quantity: order.quantity,
      limit_price: order.price,
      strategy_id: order.strategy_id
    })
  end
end
