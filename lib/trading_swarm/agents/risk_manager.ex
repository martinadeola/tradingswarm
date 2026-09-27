defmodule TradingSwarm.Agents.RiskManager do
  @moduledoc """
  Gatekeeper agent that evaluates trade signals against risk constraints.

  Risk Rules:
  - Max 2% of equity risked per trade (using ATR-based stop distance)
  - Max 30% total portfolio exposure
  - Max 15% concentration in any single symbol
  - Circuit breaker integration: blocks new entries when drawdown limits hit
  - Exit/cover trades are ALWAYS approved (must be able to close positions)
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  alias TradingSwarm.Agents.CircuitBreaker
  require Logger

  @max_risk_per_trade 0.02      # 2% of equity risked per trade
  @max_total_exposure 0.30      # 30% of equity in total positions
  @max_single_concentration 0.15 # 15% max in any single symbol

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(args) do
    id = args.strategy_id
    KnowledgeBase.subscribe(:trade_signal)
    {:ok, %{id: id}}
  end

  @impl true
  def handle_info({:fact_asserted, :trade_signal, sig}, state) do
    if sig.strategy_id == state.id do
      process_signal(sig, state.id)
      KnowledgeBase.retract(:trade_signal, sig)
    end

    {:noreply, state}
  end

  defp process_signal(sig, id) do
    act = sig.action

    port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: id}) |> List.first()

    if port == nil do
      :ok
    else
      # Always allow exits — even if circuit breaker is tripped
      if act in [:sell, :cover] do
        process_exit(sig, id, port)
      else
        process_entry(sig, id, port)
      end
    end
  end

  # --- Exit trades (always allowed) ---

  defp process_exit(sig, id, _port) do
    sym = sig.symbol
    act = sig.action
    p = sig.price

    pos = KnowledgeBase.get_by(:position, %{symbol: sym, strategy_id: id}) |> List.first()

    cond do
      act == :sell and pos != nil and pos.quantity > 0 ->
        KnowledgeBase.assert(:approved_order, %{
          symbol: sym, action: :sell, quantity: pos.quantity,
          price: p, order_type: :limit, strategy_id: id
        })

      act == :cover and pos != nil and pos.quantity < 0 ->
        quantity = abs(pos.quantity)
        KnowledgeBase.assert(:approved_order, %{
          symbol: sym, action: :cover, quantity: quantity,
          price: p, order_type: :limit, strategy_id: id
        })

      true ->
        :ok
    end
  end

  # --- Entry trades (subject to all risk checks) ---

  defp process_entry(sig, id, port) do
    sym = sig.symbol
    act = sig.action
    p = sig.price
    cash = port.cash

    # Check circuit breaker first
    unless CircuitBreaker.can_open_position?(id) do
      Logger.debug("[Risk-#{id}] Blocked #{act} on #{sym}: circuit breaker tripped")
      :rejected
    else
      # Calculate true equity and current exposure
      positions = KnowledgeBase.get_by(:position, %{strategy_id: id})

      total_exposure =
        Enum.reduce(positions, 0.0, fn pos_entry, acc ->
          latest = KnowledgeBase.get_by(:market_data, %{symbol: pos_entry.symbol}) |> List.last()
          price = if latest, do: latest.price, else: pos_entry.avg_price
          acc + abs(pos_entry.quantity) * price
        end)

      true_equity = calculate_true_equity(id, port, positions)

      # Check: would we already be at max exposure?
      if total_exposure >= true_equity * @max_total_exposure do
        Logger.debug("[Risk-#{id}] Blocked #{act} on #{sym}: total exposure #{Float.round(total_exposure, 2)} >= #{@max_total_exposure * 100}% of equity")
        :rejected
      else
        # Check: concentration limit on this symbol
        existing_sym_exposure =
          positions
          |> Enum.filter(fn pos_entry -> pos_entry.symbol == sym end)
          |> Enum.reduce(0.0, fn pos_entry, acc -> acc + abs(pos_entry.quantity) * p end)

        max_sym_allocation = true_equity * @max_single_concentration

        if existing_sym_exposure >= max_sym_allocation do
          Logger.debug("[Risk-#{id}] Blocked #{act} on #{sym}: concentration limit reached")
          :rejected
        else
          # Position sizing: risk 2% of equity per trade
          # Use ATR-based stop distance if available, otherwise use 1% of price as fallback
          atr = get_atr_for_symbol(sym)
          stop_distance = if atr > 0, do: atr, else: p * 0.01

          # shares = (equity * risk_pct) / stop_distance
          risk_amount = true_equity * @max_risk_per_trade
          ideal_quantity = trunc(risk_amount / stop_distance)

          # Cap by remaining exposure budget
          remaining_exposure = (true_equity * @max_total_exposure) - total_exposure
          remaining_sym = max_sym_allocation - existing_sym_exposure
          max_by_budget = trunc(min(remaining_exposure, remaining_sym) / p)

          quantity = min(ideal_quantity, max_by_budget)

          # Ensure we have enough cash (with 0.1% slippage buffer)
          slippage_price = if act == :buy, do: p * 1.001, else: p * 0.999
          cost = slippage_price * quantity

          if quantity > 0 and cash >= cost do
            KnowledgeBase.assert(:approved_order, %{
              symbol: sym, action: act, quantity: quantity,
              price: p, order_type: :limit, strategy_id: id
            })
          else
            :rejected
          end
        end
      end
    end
  end

  defp calculate_true_equity(_id, port, positions) do
    pos_value =
      Enum.reduce(positions, 0.0, fn pos_entry, acc ->
        latest = KnowledgeBase.get_by(:market_data, %{symbol: pos_entry.symbol}) |> List.last()
        price = if latest, do: latest.price, else: pos_entry.avg_price
        acc + pos_entry.quantity * price
      end)

    port.cash + pos_value
  end

  defp get_atr_for_symbol(sym) do
    # Try to get ATR from knowledge base (will be asserted by quant agents in Phase 4)
    case KnowledgeBase.get_by(:indicator, %{symbol: sym, name: "atr"}) |> List.last() do
      nil -> 0.0
      ind -> ind.value
    end
  end
end
