defmodule Taxi.LocationTest do
  use ExUnit.Case
  alias Taxi.Location

  describe "valid_location?/1" do
    test "retorna true para ubicaciones válidas" do
      assert Location.valid_location?("Parque") == true
      assert Location.valid_location?("Aeropuerto") == true
      assert Location.valid_location?("Centro") == true
    end

    test "es case-insensitive" do
      assert Location.valid_location?("parque") == true
      assert Location.valid_location?("PARQUE") == true
      assert Location.valid_location?("PaRqUe") == true
    end

    test "retorna false para ubicaciones inválidas" do
      assert Location.valid_location?("LugarInexistente") == false
      assert Location.valid_location?("123456") == false
    end

    test "maneja strings vacías" do
      assert Location.valid_location?("") == false
    end
  end

  describe "normalize_location/1" do
    test "normaliza ubicaciones existentes manteniendo capitalización correcta" do
      normalized = Location.normalize_location("parque")
      assert normalized == "Parque"
    end

    test "retorna el input original si no encuentra coincidencia" do
      result = Location.normalize_location("LugarRaro")
      assert result == "LugarRaro"
    end

    test "maneja diferentes capitalizaciones" do
      assert Location.normalize_location("AEROPUERTO") == "Aeropuerto"
      assert Location.normalize_location("centro") == "Centro"
    end
  end

  describe "list_locations/0" do
    test "retorna una lista de ubicaciones" do
      locations = Location.list_locations()
      assert is_list(locations)
      assert length(locations) > 0
    end

    test "contiene ubicaciones esperadas" do
      locations = Location.list_locations()
      assert "Parque" in locations
      assert "Aeropuerto" in locations
      assert "Centro" in locations
      assert "Hospital" in locations
    end

    test "todas las ubicaciones son strings" do
      locations = Location.list_locations()
      assert Enum.all?(locations, &is_binary/1)
    end
  end
end
