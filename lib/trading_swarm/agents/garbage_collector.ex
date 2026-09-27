defmodule TradingSwarm.Agents.GarbageCollector do
  use GenServer
  alias TradingSwarm.KnowledgeBase
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("[GarbageCollector] Starting background sweep...")
    # In Backtest mode, GC causes massive deadlocks on the KnowledgeBase, so we disable it
    if System.get_env("MODE") != "backtest" do
      Process.send_after(self(), :sweep, 10000)
    end
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Retract any market data older than 15 seconds
    now = DateTime.utc_now()
    
    market_data = KnowledgeBase.get_all(:market_data)
    
    count = Enum.reduce(market_data, 0, fn md, acc ->
      diff = DateTime.diff(now, md.time, :second)
      
      if diff > 15 do
        KnowledgeBase.retract(:market_data, md)
        acc + 1
      else
        acc
      end
    end)
    
    if count > 0 do
      Logger.debug("[GarbageCollector] Pruned #{count} old market_data facts from ETS.")
    end

    # Schedule next sweep in 10 seconds
    Process.send_after(self(), :sweep, 10000)
    
    {:noreply, state}
  end
end
