defmodule TradingSwarm.Agents.Oracle do
  @moduledoc """
  Live data ingestion agent. 
  
  In this portfolio demonstration version, instead of connecting to a real
  broker data feed, it generates random realistic ticks based on the configured 
  universe of symbols.
  """
  use GenServer
  alias TradingSwarm.KnowledgeBase
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("[Oracle] Starting mock live data feed...")
    symbols = Application.get_env(:trading_swarm, :universe, ["AAPL", "MSFT", "GOOG"])
    
    # Starting prices
    prices = Map.new(symbols, fn sym -> {sym, Enum.random(100..500) * 1.0} end)

    Process.send_after(self(), :poll, 1000)

    {:ok, %{
      symbols: symbols,
      prices: prices,
      poll_interval: 250 # Reduced from 2000 to fill 50-tick moving averages faster
    }}
  end

  @impl true
  def handle_info(:poll, state) do
    # Generate live ticks
    new_prices = Enum.reduce(state.symbols, state.prices, fn sym, acc_prices ->
      current_price = acc_prices[sym]
      
      # Random walk
      change_pct = (:rand.normal() * 0.001)
      new_price = current_price * (1.0 + change_pct)
      new_price = max(new_price, 1.0)
      
      vol = Enum.random(10000..50000)
      bid_size = Enum.random(100..1000)
      ask_size = Enum.random(100..1000)

      # Publish MarketData
      KnowledgeBase.assert(:market_data, %{
        symbol: sym,
        price: new_price,
        volume: vol,
        time: DateTime.utc_now()
      })

      # Retract old OrderBook
      old_obs = KnowledgeBase.get_by(:order_book, %{symbol: sym})
      Enum.each(old_obs, fn ob -> KnowledgeBase.retract(:order_book, ob) end)

      # Publish OrderBook (simulated L2/quotes)
      KnowledgeBase.assert(:order_book, %{
        symbol: sym,
        bid_volume: bid_size,
        ask_volume: ask_size
      })

      Logger.info("[Oracle] Ingested #{sym} at $#{Float.round(new_price, 2)}")
      Map.put(acc_prices, sym, new_price)
    end)

    Process.send_after(self(), :poll, state.poll_interval)
    {:noreply, %{state | prices: new_prices}}
  end
end
