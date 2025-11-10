defmodule Taxi.Location do
  use GenServer
  @data_dir "data"

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    File.mkdir_p!(@data_dir)
    locations = load_locations()
    {:ok, locations}
  end

  def valid_location?(loc) do
    GenServer.call(__MODULE__, {:valid, loc})
  end

  def normalize_location(loc) do
    GenServer.call(__MODULE__, {:normalize, loc})
  end

  def list_locations do
    GenServer.call(__MODULE__, :list)
  end

  defp locations_file_path do
    Path.join(@data_dir, "locations.json")
  end

  defp load_locations do
    file = locations_file_path()

    case File.read(file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"locations" => locs}} when is_list(locs) ->
            locs

          {:ok, locs} when is_list(locs) ->
            locs

          _ ->
            create_default_locations(file)
        end

      {:error, _} ->
        create_default_locations(file)
    end
  end

  defp create_default_locations(file) do
    default = ["Parque", "Centro", "Aeropuerto", "Estacion", "Barrio"]
    json = Jason.encode!(%{"locations" => default}, pretty: true)
    File.write!(file, json)
    default
  end

  def handle_call({:valid, loc}, _from, locations) do
    normalized = String.downcase(loc)
    found = Enum.any?(locations, fn l -> String.downcase(l) == normalized end)
    {:reply, found, locations}
  end

  def handle_call({:normalize, loc}, _from, locations) do
    normalized = String.downcase(loc)
    result = Enum.find(locations, fn l -> String.downcase(l) == normalized end)
    {:reply, result || loc, locations}
  end

  def handle_call(:list, _from, locations) do
    {:reply, locations, locations}
  end
end
