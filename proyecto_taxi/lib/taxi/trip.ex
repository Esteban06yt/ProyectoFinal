defmodule Taxi.Trip do
  use GenServer
  require Logger

  @trip_duration 20_000
  @accept_timeout 30_000

  defstruct [:id, :client, :origin, :destination, :driver, :state, :timer_ref]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(args.id))
  end

  def via_tuple(id), do: {:via, Registry, {Taxi.TripRegistry, id}}

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  def list_info(id) do
    s = GenServer.call(via_tuple(id), :info)
    %{
      "id" => Map.get(s, :id),
      "client" => Map.get(s, :client),
      "origin" => Map.get(s, :origin),
      "destination" => Map.get(s, :destination),
      "driver" => Map.get(s, :driver),
      "state" => Map.get(s, :state)
    }
  end

  def accept(id, driver) do
    GenServer.call(via_tuple(id), {:accept, driver})
  end

  def cancel(id, username) do
    GenServer.call(via_tuple(id), {:cancel, username})
  end

  def init(%{id: id, client: client, origin: origin, destination: destination}) do
    ref = make_ref()
    Process.send_after(self(), {:expire, ref}, @accept_timeout)

    state = %__MODULE__{
      id: id,
      client: client,
      origin: origin,
      destination: destination,
      driver: nil,
      state: :waiting,
      timer_ref: ref
    }

    {:ok, state}
  end

  def handle_call(:info, _from, s) do
    {:reply, Map.from_struct(s), s}
  end

  def handle_call({:accept, driver}, _from, s = %__MODULE__{state: :waiting}) do
    ref = make_ref()
    Process.send_after(self(), {:finish, ref}, @trip_duration)
    s2 = %{s | driver: driver, state: :in_progress, timer_ref: ref}

    Logger.info("Viaje #{s2.id} aceptado por #{driver}, finalizará en #{@trip_duration}ms")
    {:reply, {:ok, s2.id}, s2}
  end

  def handle_call({:accept, _driver}, _from, s) do
    {:reply, {:error, :not_available}, s}
  end

  def handle_call({:cancel, username}, _from, s = %__MODULE__{state: :waiting, client: username}) do
    Logger.info("Viaje #{s.id} cancelado por el cliente")
    write_result("#{DateTime.utc_now()}; cliente=#{s.client}; conductor=none; origen=#{s.origin}; destino=#{s.destination}; status=Cancelado\n")
    Taxi.UserManager.add_score(s.client, -3)
    {:stop, :normal, {:ok, :cancelled}, %{s | state: :cancelled}}
  end

  def handle_call({:cancel, _}, _from, s) do
    {:reply, {:error, :cannot_cancel}, s}
  end

  def handle_info({:expire, ref}, s = %__MODULE__{state: :waiting, timer_ref: ref}) do
    Logger.warning("Viaje #{s.id} expiró sin conductor")
    write_result("#{DateTime.utc_now()}; cliente=#{s.client}; conductor=none; origen=#{s.origin}; destino=#{s.destination}; status=Expirado\n")
    Taxi.UserManager.add_score(s.client, -5)
    {:stop, :normal, %{s | state: :expired}}
  end

  def handle_info({:expire, _old_ref}, s) do
    Logger.debug("Ignorando mensaje :expire obsoleto para viaje #{s.id} en estado #{s.state}")
    {:noreply, s}
  end

  def handle_info({:finish, ref}, s = %__MODULE__{state: :in_progress, timer_ref: ref, driver: driver}) do
    Logger.info("Viaje #{s.id} completado exitosamente")

    Taxi.UserManager.add_score(s.client, 10)
    Taxi.UserManager.add_score(driver, 15)

    {:ok, bonus} = Taxi.UserManager.increment_streak(driver)

    bonus_msg = case bonus do
      25 -> "¡RACHA DE 10 VIAJES! +25 pts de bono"
      10 -> "¡Racha de 5 viajes! +10 pts de bono"
      5 -> "¡Racha de 3 viajes! +5 pts de bono"
      _ -> ""
    end

    total_driver_points = 15 + bonus
    status_line = if bonus > 0 do
      "Completado (Conductor: +#{total_driver_points}pts con bono)"
    else
      "Completado"
    end

    write_result("#{DateTime.utc_now()}; cliente=#{s.client}; conductor=#{driver}; origen=#{s.origin}; destino=#{s.destination}; status=#{status_line}\n")

    if bonus > 0 do
      Logger.info("#{bonus_msg} - Total para #{driver}: +#{total_driver_points} pts")
    end

    {:stop, :normal, %{s | state: :completed}}
  end

  def handle_info({:finish, _old_ref}, s) do
    Logger.debug("Ignorando mensaje :finish obsoleto para viaje #{s.id}")
    {:noreply, s}
  end

  def handle_info(msg, s) do
    Logger.warning("Mensaje inesperado en Trip #{s.id}: #{inspect(msg)}")
    {:noreply, s}
  end

  defp write_result(line) do
    File.mkdir_p!("data")
    File.write!("data/results.log", line, [:append])
    write_json_result(line)
  end

  defp write_json_result(line) do
    parts = String.split(line, "; ")

    result_entry =
      parts
      |> Enum.reduce(%{}, fn part, acc ->
        case String.split(part, "=", parts: 2) do
          [key, value] ->
            Map.put(acc, String.trim(key), String.trim(value))
          [timestamp] ->
            Map.put(acc, "timestamp", String.trim(timestamp))
          _ ->
            acc
        end
      end)

    json_file = "data/results.json"

    existing = case File.read(json_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end
      {:error, _} -> []
    end

    updated = existing ++ [result_entry]

    json = Jason.encode!(updated, pretty: true)
    File.write!(json_file, json)
  end
end
