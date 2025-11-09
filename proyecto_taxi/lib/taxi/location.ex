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
    Path.join(@data_dir, "locations.dat")
  end

  defp load_locations do
    file = locations_file_path()

    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)

      _ ->
        default = ["Parque", "Centro", "Aeropuerto", "Estacion", "Barrio"]
        File.write!(file, Enum.join(default, "\n"))
        default
    end
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
